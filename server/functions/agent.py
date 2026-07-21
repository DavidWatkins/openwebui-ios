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
- Any length or format request (e.g. "one sentence", "just the number", "briefly") \
applies ONLY to your FINAL answer after the tool result. For the tool-call step, output \
ONLY the JSON and ignore formatting requests.
Never mention this protocol or the JSON to the user.

Examples:
User: what's the weather in Paris?
Assistant: {"tool": "weather", "location": "Paris, France"}
User: temperature in Miami right now, just the number?
Assistant: {"tool": "weather", "location": "Miami, Florida"}
User: latest Go version, one sentence?
Assistant: {"tool": "web_search", "query": "latest stable Go version"}
User: explain recursion
Assistant: Recursion is when a function calls itself to solve smaller subproblems..."""

_CALL_RE = re.compile(r'\{[^{}]*"tool"\s*:\s*"[a-z_]+"[^{}]*\}', re.DOTALL)
_COOLDOWN_RE = re.compile(r'cooldown:\s*(\S+)\s+loaded', re.I)
# Weather questions get deterministic routing (see pipe()) because the non-thinking
# model refuses the weather tool.
_WEATHER_INTENT = re.compile(
    r"\b(weather|temperature|forecast|how (?:hot|cold|warm)|humidity|degrees|"
    r"raining|snowing|windy)\b",
    re.I,
)
_LOC_RE = re.compile(r'\{[^{}]*"location"[^{}]*\}', re.DOTALL)
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
        # Two variants surface as models in the picker: pick "thinking" per chat
        # for deep reasoning (slower), or the fast default for everything else.
        return [
            {"id": "agent", "name": "Agent (tools)"},
            {"id": "agent_think", "name": "Agent (tools, thinking)"},
        ]

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

    def _geocode(self, name: str) -> Optional[dict]:
        try:
            g = requests.get("https://geocoding-api.open-meteo.com/v1/search",
                             params={"name": name, "count": 1}, timeout=10).json()
            hits = g.get("results") or []
            return hits[0] if hits else None
        except Exception:
            return None

    def _weather(self, location: str) -> Tuple[str, list]:
        try:
            # Open-Meteo geocoding wants a bare place name — "Boston, Massachusetts"
            # returns 0 results, so fall back to the part before the first comma.
            loc = self._geocode(location) or (self._geocode(location.split(",")[0].strip())
                                              if "," in location else None)
            if not loc:
                return f"[weather: could not find '{location}']", []
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

    async def _extract_location(self, request, user, text: str) -> str:
        out = await self._model(request, user, [
            {"role": "system", "content": 'Extract the place the user is asking about. '
             'Reply with ONLY JSON: {"location": "City, Region"} — or {"location": ""} if none.'},
            {"role": "user", "content": text},
        ])
        m = _LOC_RE.search(out or "")
        if not m:
            return ""
        try:
            return (json.loads(m.group(0)).get("location") or "").strip()
        except Exception:
            return ""

    async def _model(self, request, user, messages, think: Optional[bool] = None) -> str:
        model = self._loaded_model or self.valves.base_model
        thinking = self.valves.enable_thinking if think is None else think
        async def call(mid):
            try:
                resp = await generate_chat_completion(
                    request,
                    {"model": mid, "messages": messages, "stream": False,
                     "chat_template_kwargs": {"enable_thinking": thinking}},
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
        # "Agent (tools, thinking)" variant → reason on the final answer.
        turn_think = str(body.get("model", "")).endswith("agent_think")

        async def emit(desc, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": desc, "done": done}})

        base_msgs = list(body.get("messages", []))
        conv = [{"role": "system", "content": TOOL_DOC}] + base_msgs
        sources, content = [], ""

        # Deterministic weather routing: with thinking off, Qwen's "I can't do
        # real-time weather" prior makes it refuse the weather tool. An extraction
        # prompt doesn't trip that prior, so we pull the location and run the tool
        # ourselves, seeding the result before the main loop.
        last_user = next((m.get("content") for m in reversed(base_msgs)
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")
        weather_result = None  # fetched weather text, used as a hard fallback
        if last_user and _WEATHER_INTENT.search(last_user):
            loc = await self._extract_location(__request__, user, last_user)
            if loc:
                await emit(f"🔧 weather: {loc}")
                result, _ = self._weather(loc)
                if not result.startswith("["):
                    weather_result = result
                conv.append({"role": "assistant", "content": json.dumps({"tool": "weather", "location": loc})})
                conv.append({"role": "user", "content":
                    f"Here is the CURRENT, real-time weather, just fetched from a live source:\n{result}\n\n"
                    "This data is accurate and up to date. Answer my previous question using it directly. "
                    "Do NOT say you lack real-time access or that you cannot provide weather — you have it above. "
                    "Do not output JSON."})

        for _ in range(self.valves.max_iterations):
            content = await self._model(__request__, user, conv, think=turn_think)
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
            content = await self._model(__request__, user, [m for m in conv if m.get("role") != "system"], think=turn_think) or "…"

        # Hard fallback: if we fetched valid weather but the model still hedged
        # (no temperature in the reply, or a "can't/couldn't/unable" disclaimer),
        # reformat the fetched data to the user's request with a fresh call (a
        # rewrite of provided data doesn't trip the refusal prior); if that also
        # hedges, return the raw data directly — reliability over prettiness.
        _HEDGE = r"\b(can'?t|cannot|couldn'?t|unable|do(?:n'?t| not) have|no access)\b"
        if weather_result and (not re.search(r"\d", content)
                or re.search(_HEDGE, content, re.I)):
            reformatted = await self._model(__request__, user, [
                {"role": "system", "content": "Rewrite the given weather data to answer the user's "
                 "request in their requested style/length. Output only the answer — no disclaimers, "
                 "no mention of data sources or access."},
                {"role": "user", "content": f"User asked: {last_user}\n\nWeather data: {weather_result}"},
            ])
            if re.search(r"\d", reformatted) and not re.search(_HEDGE, reformatted, re.I):
                content = reformatted
            else:
                content = weather_result

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
