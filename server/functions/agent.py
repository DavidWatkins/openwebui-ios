"""
title: Agent
author: openwebui-ios
description: Server-side agentic tool loop via prompt-based tool calling. Phase 1 (non-streaming): the model decides + runs tools (SearXNG web search, Open-Meteo weather), collecting source URLs. Phase 2 (streaming): the final answer is streamed token-by-token, then a Sources list is appended. Exposes itself as a model so the plain /api/chat/completions API gets contextual tools + streaming + citations with no socket.io. Auto-detects the loaded model to survive the router swap cooldown.
version: 0.8.0
required_open_webui_version: 0.6.0
"""
import json
import re
import requests
from typing import List, Optional, Tuple
from pydantic import BaseModel, Field
from open_webui.utils.chat import generate_chat_completion
from open_webui.models.users import Users

DECISION_DOC = """You can call tools. Decide if one is needed for the user's latest \
message. If so, reply with ONLY a single-line JSON object and nothing else:
- Web search: {"tool": "web_search", "query": "<search terms>"}
- Current weather: {"tool": "weather", "location": "<City, Region>"}
Use web_search for news, prices, releases, recent events, today's date, or verifying a \
claim; use weather for current conditions. If NO tool is needed, reply with ONLY the \
word: NONE. Do not answer the question in this step."""

ANSWER_DOC = """Answer the user's most recent question directly and concisely. If tool \
results appear above, use them as your source of truth. Do not output JSON and do not \
mention tools or this instruction."""

_CALL_RE = re.compile(r'\{[^{}]*"tool"\s*:\s*"[a-z_]+"[^{}]*\}', re.DOTALL)
_COOLDOWN_RE = re.compile(r'cooldown:\s*(\S+)\s+loaded', re.I)
_WMO = {
    0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog",
    48: "rime fog", 51: "light drizzle", 53: "drizzle", 55: "dense drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain",
    67: "heavy freezing rain", 71: "light snow", 73: "snow", 75: "heavy snow",
    77: "snow grains", 80: "light showers", 81: "showers", 82: "violent showers",
    85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
    96: "thunderstorm w/ hail", 99: "severe thunderstorm w/ hail",
}


class Pipe:
    class Valves(BaseModel):
        base_model: str = Field(default="qwen3.6-27b-fp8", description="Preferred base model (auto-falls back to whatever is loaded)")
        searxng_url: str = Field(default="http://searxng:8080/search")
        max_results: int = Field(default=6)
        max_iterations: int = Field(default=3)

    def __init__(self):
        self.valves = self.Valves()
        self._loaded_model: Optional[str] = None

    def pipes(self) -> List[dict]:
        return [{"id": "agent", "name": "Agent (tools)"}]

    # ---- tools: return (text_for_model, [(title, url), ...]) ----
    def _web_search(self, query: str) -> Tuple[str, list]:
        try:
            r = requests.get(self.valves.searxng_url, params={"q": query, "format": "json"}, timeout=12)
            r.raise_for_status()
            results = (r.json().get("results") or [])[: self.valves.max_results]
        except Exception as e:
            return f"[web_search error: {e}]", []
        if not results:
            return "[web_search: no results]", []
        text = "\n\n".join(
            f"[{i}] {it.get('title','')}\n{(it.get('content') or '')[:400]}\n{it.get('url','')}"
            for i, it in enumerate(results, 1)
        )
        srcs = [(it.get("title") or it.get("url", ""), it.get("url", "")) for it in results if it.get("url")]
        return text, srcs

    def _weather(self, location: str) -> Tuple[str, list]:
        try:
            g = requests.get("https://geocoding-api.open-meteo.com/v1/search",
                             params={"name": location, "count": 1}, timeout=10).json()
            hits = g.get("results") or []
            if not hits:
                return f"[weather: could not find '{location}']", []
            loc = hits[0]
            name = ", ".join(x for x in [loc.get("name"), loc.get("admin1"), loc.get("country_code")] if x)
            w = requests.get("https://api.open-meteo.com/v1/forecast", params={
                "latitude": loc["latitude"], "longitude": loc["longitude"],
                "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
                "temperature_unit": "fahrenheit", "wind_speed_unit": "mph"}, timeout=10).json()
            c = w.get("current", {})
            desc = _WMO.get(c.get("weather_code"), f"code {c.get('weather_code')}")
            return (f"Weather for {name}: {desc}, {c.get('temperature_2m')}°F "
                    f"(feels {c.get('apparent_temperature')}°F), humidity {c.get('relative_humidity_2m')}%, "
                    f"wind {c.get('wind_speed_10m')} mph."), []
        except Exception as e:
            return f"[weather error: {e}]", []

    def _execute(self, call: dict) -> Tuple[str, list]:
        t = call.get("tool")
        if t == "web_search":
            return self._web_search(call.get("query", ""))
        if t == "weather":
            return self._weather(call.get("location", ""))
        return f"[unknown tool: {t}]", []

    def _parse_call(self, content: str) -> Optional[dict]:
        m = _CALL_RE.search(content or "")
        if not m:
            return None
        try:
            obj = json.loads(m.group(0))
        except Exception:
            return None
        return obj if obj.get("tool") in ("web_search", "weather") else None

    # ---- model plumbing ----
    async def _raw(self, request, user, model, messages, stream):
        return await generate_chat_completion(
            request, {"model": model, "messages": messages, "stream": stream}, user
        )

    async def _model(self, request, user, messages) -> str:
        """Non-streaming call, with router-cooldown auto-detect."""
        model = self._loaded_model or self.valves.base_model
        try:
            resp = await self._raw(request, user, model, messages, False)
            data = resp if isinstance(resp, dict) else (json.loads(resp.body) if hasattr(resp, "body") else {})
        except Exception as e:
            data = {"__err__": str(e)}
        if "choices" not in data:
            hit = _COOLDOWN_RE.search(str(data.get("detail") or data.get("error") or data.get("__err__") or ""))
            if hit:
                self._loaded_model = hit.group(1)
                try:
                    resp = await self._raw(request, user, self._loaded_model, messages, False)
                    data = resp if isinstance(resp, dict) else (json.loads(resp.body) if hasattr(resp, "body") else {})
                except Exception:
                    data = {}
        try:
            return data["choices"][0]["message"].get("content") or ""
        except (KeyError, IndexError, TypeError):
            return ""

    async def _stream(self, request, user, messages):
        """Streaming call; yields content deltas. Uses the model resolved in phase 1."""
        model = self._loaded_model or self.valves.base_model
        resp = await self._raw(request, user, model, messages, True)
        itr = getattr(resp, "body_iterator", None) or resp
        buf = ""
        async for chunk in itr:
            if isinstance(chunk, (bytes, bytearray)):
                chunk = chunk.decode("utf-8", "ignore")
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    return
                try:
                    delta = json.loads(payload)["choices"][0]["delta"].get("content")
                except Exception:
                    delta = None
                if delta:
                    yield delta

    async def pipe(self, body: dict, __user__=None, __request__=None, __event_emitter__=None):
        user = await Users.get_user_by_id(__user__["id"]) if isinstance(__user__, dict) else __user__

        async def emit(desc, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": desc, "done": done}})

        base_msgs = list(body.get("messages", []))

        # Phase 1 — tool loop (non-streaming). Collect tool exchanges + sources.
        conv = [{"role": "system", "content": DECISION_DOC}] + base_msgs
        tool_exchanges, sources = [], []
        for _ in range(self.valves.max_iterations):
            content = await self._model(__request__, user, conv)
            call = self._parse_call(content)
            if not call:
                break
            await emit(f"🔧 {call.get('tool')}: {call.get('query') or call.get('location') or ''}")
            result, srcs = self._execute(call)
            sources.extend(srcs)
            ex = [
                {"role": "assistant", "content": json.dumps(call)},
                {"role": "user", "content": f"Tool result:\n{result}"},
            ]
            tool_exchanges.extend(ex)
            conv.extend(ex)
        await emit("done", done=True)

        # Phase 2 — stream the final answer.
        answer_msgs = [{"role": "system", "content": ANSWER_DOC}] + base_msgs + tool_exchanges
        streamed = False
        async for delta in self._stream(__request__, user, answer_msgs):
            streamed = True
            yield delta
        if not streamed:  # streaming path failed → non-stream fallback
            yield (await self._model(__request__, user, answer_msgs)) or "…"

        # Citations — dedup by URL, cap at 6.
        if sources:
            seen, uniq = set(), []
            for title, url in sources:
                if url and url not in seen:
                    seen.add(url)
                    uniq.append((title, url))
            if uniq:
                yield "\n\n---\n**Sources**\n" + "\n".join(
                    f"{i}. [{(t or u)[:80]}]({u})" for i, (t, u) in enumerate(uniq[:6], 1)
                )
