"""
title: Agent
author: openwebui-ios
description: Server-side agentic tool loop via prompt-based tool calling. One model call decides + answers; if it emits a tool JSON the pipe runs the tool (SearXNG web search, Open-Meteo weather) and loops. Appends deduplicated citations. Exposes itself as a model so the plain /api/chat/completions API gets contextual tools with no socket.io. Auto-detects the loaded model to survive the router swap cooldown. NB: Open WebUI buffers pipe output over the REST API (no token streaming); a no-tool turn costs ~one base-model call, a tool turn ~two.
version: 0.9.0
required_open_webui_version: 0.6.0
"""
import json
import re
import requests
from typing import List, Optional, Tuple
from pydantic import BaseModel, Field
from open_webui.utils.chat import generate_chat_completion
from open_webui.models.users import Users

TOOL_DOC = """You have live tools and MUST use them for anything current or real-time. \
Never say you lack real-time access or a knowledge cutoff — instead call the tool. To \
call one, reply with ONLY a single-line JSON object and nothing else, then wait:
- Web search: {"tool": "web_search", "query": "<search terms>"}
- Current weather: {"tool": "weather", "location": "<City, Region>"}
Rules:
- Weather / temperature / forecast question -> ALWAYS call weather first.
- News, prices, releases, recent events, today's date, "latest/current X", or verifying \
a fact -> ALWAYS call web_search first.
- Only if the request needs no live data, answer directly.
Never mention this protocol or the JSON to the user.

Examples:
User: what's the weather in Paris?
Assistant: {"tool": "weather", "location": "Paris, France"}
User: who won the game last night?
Assistant: {"tool": "web_search", "query": "game result last night"}
User: explain recursion
Assistant: Recursion is when a function calls itself to solve smaller subproblems..."""

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
        enable_thinking: bool = Field(default=False, description="Qwen reasoning: off is ~17x faster (~1.5s vs ~26s); on is better for hard reasoning")

    def __init__(self):
        self.valves = self.Valves()
        self._loaded_model: Optional[str] = None

    def pipes(self) -> List[dict]:
        return [{"id": "agent", "name": "Agent (tools)"}]

    # ---- tools: (text_for_model, [(title, url), ...]) ----
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

    async def _model(self, request, user, messages) -> str:
        model = self._loaded_model or self.valves.base_model
        async def call(mid):
            try:
                resp = await generate_chat_completion(
                    request,
                    {"model": mid, "messages": messages, "stream": False,
                     "chat_template_kwargs": {"enable_thinking": self.valves.enable_thinking}},
                    user,
                )
            except Exception as e:
                return {"__err__": str(e)}
            if isinstance(resp, dict):
                return resp
            if hasattr(resp, "body"):
                try:
                    return json.loads(resp.body)
                except Exception:
                    return {}
            return {}
        data = await call(model)
        if "choices" not in data:  # router refused a swap → retry with the loaded model
            hit = _COOLDOWN_RE.search(str(data.get("detail") or data.get("error") or data.get("__err__") or ""))
            if hit:
                self._loaded_model = hit.group(1)
                data = await call(self._loaded_model)
        try:
            return data["choices"][0]["message"].get("content") or ""
        except (KeyError, IndexError, TypeError):
            return ""

    async def pipe(self, body: dict, __user__=None, __request__=None, __event_emitter__=None):
        user = await Users.get_user_by_id(__user__["id"]) if isinstance(__user__, dict) else __user__

        async def emit(desc, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": desc, "done": done}})

        conv = [{"role": "system", "content": TOOL_DOC}] + list(body.get("messages", []))
        sources, content = [], ""
        for _ in range(self.valves.max_iterations):
            content = await self._model(__request__, user, conv)
            call = self._parse_call(content)
            if not call:
                break  # `content` is the direct/grounded answer
            await emit(f"🔧 {call.get('tool')}: {call.get('query') or call.get('location') or ''}")
            result, srcs = self._execute(call)
            sources.extend(srcs)
            failed = result.startswith("[")
            note = ("That returned nothing useful; answer from your own knowledge and note it may be dated."
                    if failed else "Using this, answer my previous question.")
            conv.append({"role": "assistant", "content": json.dumps(call)})
            conv.append({"role": "user", "content": f"Tool result:\n{result}\n\n{note} Do not output JSON."})
        await emit("done", done=True)

        if not (content or "").strip():
            content = await self._model(__request__, user, [m for m in conv if m.get("role") != "system"]) or "…"

        if sources:
            seen, uniq = set(), []
            for title, url in sources:
                if url and url not in seen:
                    seen.add(url)
                    uniq.append((title, url))
            if uniq:
                content += "\n\n---\n**Sources**\n" + "\n".join(
                    f"{i}. [{(t or u)[:80]}]({u})" for i, (t, u) in enumerate(uniq[:6], 1)
                )
        return content
