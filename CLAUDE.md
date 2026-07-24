# openwebui-ios — David's fork

Native SwiftUI iOS/macOS client for a self-hosted Open WebUI instance. Upstream:
https://github.com/JoaoZaokk/openwebui-ios. Goal of this fork: close the gap
with the official Claude iOS app experience, backed by David's homelab
Open WebUI server (reachable over Tailscale).

## Architecture

- `App/` — SwiftUI app. Features are folders under `App/Features/`
  (Chat, Sessions, Voice, Images, Notes, Workspace, Settings, Auth).
- `OpenWebUIKit/` — Swift package wrapping the Open WebUI REST +
  OpenAI-compatible API. All server I/O lives here. Has tests.
- The **Agent pipe** (`agent.agent` / `agent.agent_think`) is server-side and
  lives in the homelab repo now, NOT here:
  `~/workspace/homelab/stacks/eversong/services/openwebui/functions/agent.py`
  (deploy via `POST /api/v1/functions/id/agent/update`). This repo is a clean
  OWUI client — tool cards also work against stock OWUI native web search, no
  pipe required.
- Everything is server-backed and in-memory only: `ChatStore`
  (`App/Features/Sessions/SessionStore.swift`) refetches the chat list each
  load; `ChatViewModel` fetches full history per chat. Nothing conversation-
  related is persisted on device. `OWChatPersistence.swift` = saving *to* the
  server, not locally.
- Caveat to preserve while editing: `OWChatPayload` flattens Open WebUI's
  branching history into a linear chain, and `updateChat` replaces the full
  message set — careless writes can clobber branches created in the web UI.
- Streaming: `ChatCompletionsClient.swift` emits `OWStreamUpdate`
  (`textDelta`, `reasoningDelta`, ...). UI strings are pt-BR in source with
  `Localizable.strings` for ~40 languages.

## TODO (rough priority order)

1. ~~**Local conversation cache / offline review**~~ — DONE (read-only offline).
   `CachedServerChat` (SwiftData, in `SessionStore.swift`) mirrors server chats:
   `ChatStore.load` caches the list + serves it offline; opening a chat caches
   its full tree and falls back to the cache when the server is unreachable;
   `persistTree` keeps the cache in step with writes. `OWMessage.encode` now
   persists `parentId` so the cached tree doesn't flatten (regression-tested).
   Offline is read-only — composing offline (queue + sync) is a later step.
2. ~~**Surface reasoning/thinking**~~ — DONE. Collapsible disclosure under the
   speaker header (`MessageBubble.reasoningView`). Socket path separates the
   `reasoning` output block from the `message` block; the `agent_think` pipe
   re-attaches its internal reasoning as a `<think>` block so it's auditable.
3. ~~**Edit / regenerate / retry with different model**~~ — DONE. `ChatViewModel`
   now retains the full history tree (not just the active branch) and edit/
   regenerate/retry add sibling nodes + move the leaf — nothing is deleted, so
   branches survive. New tree-preserving write path (`OWChatPayload(tree:currentId:)`
   / `updateChatTree`) computes childrenIds from parentId instead of flattening;
   `persistTree` adopts web-added nodes before writing so it can't clobber them.
   MessageBubble has a `‹ n/m ›` branch switcher, edit (user), and regenerate /
   retry-with-model (assistant). Server chats persist the tree; local branch nav
   is in-session only.
4. **Background completion + notification** — PARTIAL. Local-notification tier
   shipped: a backgrounded server reply finishes in a `UIApplication` bg task
   and posts a local `UNUserNotification` on completion (`ChatViewModel`,
   `LocalNotifier`). Backlog: always-on push for a *fully closed* app — opt-in
   ntfy topic (pipe POSTs on completion, gated behind a valve) or an APNs relay.
   Keep the App Store default dependency-free.
5. **Share extension** — share URL/PDF/text from other apps into a new chat
   (the client already has `processWebPage` + file upload plumbing).
6. ~~**Auto-title new chats**~~ — DONE. After a new server chat's first reply,
   `ChatViewModel.autoTitle` calls `client.generateTitle` (a base-model
   completion with thinking OFF — the OWUI title task endpoint ignores
   `enable_thinking` and the reasoning models burn the budget) and `renameChat`
   (partial update, merges — doesn't clobber messages). Router cooldown handled
   by retrying with the loaded model. Local/temporary chats keep the truncated
   first-message title.
7. **Full-text conversation search** — current search is a client-side title
   filter in `MainView.swift`; falls out mostly for free after (1) if the
   cache is queryable.
8. **Folders/tags in the chat list** — server supports both; app shows a flat
   pinned+recent list.
9. **Multi-server profiles** — `ServerConfig` holds a single base URL; want
   e.g. LAN vs Tailscale endpoints.
10. **Polish tier** — Face ID app lock, App Intents/Siri, widgets, artifact-
    style HTML/SVG preview, web-search citation rendering.
