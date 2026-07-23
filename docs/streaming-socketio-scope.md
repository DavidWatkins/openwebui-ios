# Scope: true token streaming (Open WebUI socket.io)

## Why this is needed
Open WebUI **buffers pipe output over the REST API** — proven with a controlled
test (a pipe that yields chunks 1s apart; the `created` timestamps are 1s apart
but every chunk arrives at the client at once). So the Agent pipe can't stream
token-by-token over `/api/chat/completions`. The web UI streams because it uses
the **socket.io** flow. To get true streaming in the app, we replicate that.

## Confirmed protocol (OWUI 0.10.2 source + live tests on your-owui-host.example)
1. **Connect** — websocket only to `wss://your-owui-host.example/ws/socket.io`
   (`transport=polling` returns "Invalid transport"). Auth on connect:
   `auth: { token: <JWT> }`.
2. **Register** — emit `user-join` with `{ auth: { token: <JWT> } }`; the server
   binds the `sid` to the user and returns `{ id, name }`.
   *Gotcha: this needs the login **JWT**, not an API key. The app already has the
   JWT (keychain, from sign-in). My capture failed only because I used the API key.*
3. **Fire** — `POST /api/chat/completions` with
   `{ model, messages, stream: true, chat_id, id: <assistant msg id>, session_id: <sid> }`.
   Returns `{ status, task_ids }` immediately (runs as a background task).
   The chat + the assistant message must already exist (`POST /api/v1/chats/new`).
4. **Receive** — server emits **`chat-events`** to the `session_id` with
   `{ chat_id, message_id, data: { type, ... } }`. `data.type`:
   - `message` / `replace` → streaming assistant content deltas
   - `status` → tool-run / search status (drives a "🔧 searching…" affordance)
   The final message is also written to the chat object (history persists).

## Build (app side)
### A. Socket client
- **Option 1 — dependency**: add `socket.io-client-swift` (SPM). Handles
  Engine.IO/Socket.IO framing, reconnection. Fastest to working; adds a package
  to `project.yml`.
- **Option 2 — hand-rolled** over `URLSessionWebSocketTask`: implement the
  Engine.IO v4 handshake (`0{…}` open, `40` connect, `2`/`3` ping-pong) + Socket.IO
  framing (`42["event",payload]`) + reconnect. No dependency, more code, fiddlier.

### B. Send-path rework
- A socket completion path: ensure the chat exists → connect + `user-join` (JWT,
  once per app session) → POST with `chat_id`/`session_id`/`id` → consume
  `chat-events`, map `data.type` to the existing streaming UI (deltas → append,
  `status` → tool indicator).
- Coexistence: use socket for **all** chats (unifies the path) or only when the
  selected model is a pipe. The current SSE path can stay as a fallback.

### C. Rendering
- Deltas → existing `MessageBubble` streaming (already handles text/reasoning).
- `status` → small "running tool" row.
- Sources → already appended to content by the pipe (render as-is), or render
  structured sources if OWUI sends them separately.

## Effort & risk
- Socket client: ~1–2 days (dependency) / ~3–4 days (hand-rolled).
- Send-path + event mapping: ~2–3 days.
- Lifecycle polish (reconnect, token refresh, **backgrounding** mid-stream): ~1–2 days.
- **Total ≈ 1 week**, medium-high complexity. I can test each step live.
- Risks: socket lifecycle on mobile (app backgrounding drops the socket — ties into
  TODO #4 "background completion"); OWUI version drift in event shapes; chat/message
  id bookkeeping must match OWUI's expectations.

## Lighter alternative (no socket.io)
**Client-orchestrated streaming**: app calls a *tools-only* endpoint (fast,
buffered) to get tool results, then streams the answer from the **base model**
directly over SSE (base models DO stream). Gives streamed answers + server tools,
no socket lifecycle. ~half the effort, but needs a small tools-only server
endpoint + app orchestration + re-sending context, and loses live tool-status.

## Recommendation
- Full fidelity (deltas + live tool status, exactly like the web UI) → socket.io,
  Option A-1 (dependency) for speed. ~1 week.
- Just want the answer to stream, OK without live tool-status → client-orchestrated
  (~half, no dependency).
