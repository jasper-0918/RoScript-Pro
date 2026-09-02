# RoScript Pro — Roblox Studio Plugin, v1 Design

**Date:** 2026-09-02 · **Status:** approved design, pre-implementation
**Repo home:** `studio-plugin/RoScriptPro.lua` (this repo) · **Author flow:** feature branch → PR → Jasper merges

RoScript Pro today is a single-file HTML chat assistant (`roblox-lua-assistant.html`). This spec ports its *design* — free-tier provider rotation, key stacking, a Roblox-strict system prompt, skill packs — into a native Roblox Studio plugin written in Luau, and adds the two things only a plugin can do: **read the open place** (Explorer selection + active script travel with each message) and **act on it** (one-click Insert as Script, preview-gated Run in Studio, both undoable). Personal use only. $0 rule: free API tiers, no paid calls.

Every Roblox API claim in this spec was checked against create.roblox.com docs on 2026-09-02 (URL + quote). Claims the docs would not confirm are marked **[unverified]**; each is either gated by a spike below or explicitly designed for worst case. Response-dictionary field names (`Success`/`StatusCode`/`Body`/`Headers`) and `plugin.Unloading` are standard API surface not separately quoted; spike 4 exercises them live.

---

## 1. Settled decisions (do not reopen without cause)

- **v1 scope:** lean core + skill packs. Chat dock, Groq/OpenRouter/Cerebras rotation, auto context with an off toggle, Insert + Run. No web search, no image gen, no artifacts panel, no chat persistence, no streaming.
- **One file**, `studio-plugin/RoScriptPro.lua`, banner sections, no Rojo, no build step. Install = copy into the local Plugins folder.
- **Keys** live in `plugin:SetSetting` storage on Jasper's machine — plaintext (the docs offer no secret storage; the settings panel says so out loud). Keys never enter the repo or the file.
- **Nothing runs or writes without a click**, and **no undo recording ⇒ no write**: Insert and Run both refuse rather than act un-undoably.
- **No streaming in v1.** `HttpService:RequestAsync` is complete-response-only. (`HttpService:CreateWebStreamClient` now exists with documented SSE support — a real v2 candidate, but unverified in the plugin security context.)
- Port **concepts**, not machinery: the HTML app's 40-round continuation loop, sandbox self-check, refusal-detection loop, Tavily, vision, and image gen do not port. One continuation round, a refusal *note*, and that's it.
- **Field check (2026-09-02):** no shipping free plugin matches this constraint set. Ropanion (closest) is OpenRouter-only — under the $0 rule that's a 50-req/day cap, a smaller cage than the one being escaped; RoCode caps at 15 msgs/day via its author's backend; StudByStud is paid; all of them take your API keys into someone else's code. Roblox's built-in Studio MCP server is the credible zero-build alternative but moves the chat *outside* Studio. The $0 multi-provider rotation with keys-in-own-code exists nowhere else — that is the reason this build exists.

## 2. Spike checklist — run in Studio before coding (gates the build)

Jasper at the keyboard, Claude driving instructions. Items 1–5 gate design choices; 6–8 are cheap confirmations; 9 needs no Studio.

**One-day build order (council-adjudicated):** spikes **1 and 4 first** for Jasper's Studio time (~20 minutes — they carry the whole transport and dev-loop bet); spikes 2/3/5–8 fold in as their sections are exercised. Claude writes the file in parallel, core-first (**UI shell → provider → context** — the midday bar is *chat with auto-context sending and rendering* — then Insert, then Run + settings polish): spike results flip CONFIG constants and the Run-engine flag, never the architecture. If the clock wins, v1 ships as chat + context + rotation, and Insert/Run/settings become v1.1; that outcome still beats the browser tab on the thing only a plugin can do.

| # | Spike | Decides |
|---|-------|---------|
| 1 | **Plugins-folder drop-in.** 3-line `print` plugin → `Copy-Item` to `%LOCALAPPDATA%\Roblox\Plugins` → restart Studio → check Output. If the folder path is wrong, do *Save as Local Plugin* once and find where Studio actually wrote it. Then: enable **Plugin Debugging Enabled**, edit the file, `PluginDebugService → Save and Reload Plugin`, confirm the change lands. | The whole dev loop (§10). Path is community knowledge, **[unverified]** in docs. |
| 2 | **Run engines.** Same throwaway plugin, two named engines: **loadstring** (`loadstring("return 1")`, then a compiled chunk doing `Instance.new("Part", workspace)`) and **module-require** (same chunk via `ModuleScript` + `require` — unparented, parented to ServerStorage, and re-required after `:Destroy()`, the module-cache check). Confirm compile errors surface through `pcall`. | Which Run engine ships (§7). Both are **[unverified]** in docs. Both pass → ship **loadstring** (no DataModel churn, no module cache); only one passes → that one; both fail → v1 ships Insert-only and Run is cut. |
| 3 | **Script-injection permission.** From the local plugin: `Instance.new("Script")`, set `.Source`, parent to ServerScriptService. Watch for a permission prompt or error; if Plugin Management shows a Script Injection toggle for the plugin, revoke and repeat. | Insert's error copy and whether first-run needs a grant step (§7). |
| 4 | **Timeout + generation timing.** From the plugin, time: Groq `gpt-oss-120b` at `max_tokens=4096`; OpenRouter `gpt-oss-120b:free` at 2048; **one call each to Cerebras `zai-glm-4.7` and OpenRouter `nemotron-3-super:free`** (both are reasoning-family models with no `reasoning_effort` control — if either burns hidden-reasoning wall clock, it is cut by §5's own rule); a request to `httpbin.org/delay/40` to measure the real default timeout; dump `resp.Headers` on a forced 429 to check `Retry-After` casing. (Optional, informational for the v2 streaming candidate only: pass `Timeout=25` once to see it accepted.) | Final `MAXTOK` table and which chain entries survive (§5). Default timeout is undocumented. |
| 5 | **`reasoning_effort` acceptance.** One minimal completion per provider with the field set. | Whether `classifyFailure` needs strip-and-retry-once for an unknown-parameter 400 (§5). Cerebras/OpenRouter most suspect. |
| 6 | **HTTP gating.** Fresh place, `HttpEnabled=false`, plugin fires one request to a never-used domain. | Confirms **[unverified]**: plugin HTTP ignores the place setting, and local plugins bypass the per-domain permission prompt (DevForum-sourced). Sets the Plugin-Management error copy. |
| 7 | **`FinishRecording(Cancel)` semantics.** Record around a part-creating snippet, then Cancel: does the part vanish or stay? | Run's failure path. Until proven, Commit-on-error stands (§7). |
| 8 | **Bubble layout + copy-out + paste-in.** Throwaway widget: ScrollingFrame + `AutomaticCanvasSize=Y` + 30 `AutomaticSize=Y` wrapped-text frames in a loop. In the same widget: a read-only `TextEditable=false` TextBox — confirm select-all + Ctrl+C actually copies out (the View modal is the ONLY code-copy path); and paste a 5-line error trace into a `MultiLine=false` TextBox to see what survives. | §4's layout fallback; whether the copy-out affordance works at all; what multiline pastes do to the composer. |
| 9 | **Model slug liveness** (optional, no Studio). The rotation self-heals: a dead slug classifies as model-error and fails over, so the first live send is itself the probe. Run a keyed curl only if the chain ever feels mysteriously thin. | Nothing gates on this — the chain is data and dead slugs are one-line deletions. |

## 3. File layout

`studio-plugin/RoScriptPro.lua`, target ~1,300 lines, banner style `-- ═══════ SECTION ═══════`. Sections are mostly bottom-up, but PROVIDER/APPLY code must surface status and bubbles from the later UI section — so CONFIG forward-declares a `UI = { setStatus = noop, addBubble = noop, setBusy = noop }` hooks table that the UI section fills in; lower sections only ever call through `UI.*`, never a bare forward reference.

| # | Section | Contents | ~Lines |
|---|---------|----------|--------|
| 0 | HEADER | Version, install one-liner, reload steps, `local DEV=false` trace flag | 25 |
| 1 | CONFIG | `PROV` urls, `MODEL_CHAIN`, `MAXTOK`, size caps, `HISTORY_MAX_MSGS=12`, `HISTORY_MAX_CHARS=15000` | 70 |
| 2 | SETTINGS | `S.get/S.set` cache wrapper, `KeyStore` | 80 |
| 3 | PROMPT & SKILLS | `SYS_BASE`, `SKILLS` (7 packs), `buildSystemPrompt()` | 190 |
| 4 | CONTEXT | `summarizeInstance`, `buildSelectionSummary`, `getActiveScriptBlock`, `buildContext`, `utf8Trim` | 120 |
| 5 | PROVIDER | `Cooling`/`Bad` state, `buildQueue`, `classifyFailure`, `callProvider`, `chatOnce`, `chatWithContinuation`, `looksLikeRefusal` | 230 |
| 6 | APPLY & RUN | `parsePlacement`, `insertScript`, `runOnce`, preview modal | 170 |
| 7 | UI | `mk()` helper, palette, `buildUI`, `splitBlocks`, `escapeRich`, `addBubble`, `renderCodeBlock`, source modal, `setBusy`, `setStatus`, settings panel | 350 |
| 8 | BOOTSTRAP | Toolbar, button, widget, generation counter, event wiring, `sendMessage` | 90 |

## 4. UI

**Widget:** `plugin:CreateDockWidgetPluginGuiAsync("RoScriptProChat", DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 380, 520, 300, 350))`, `widget.Title = "RoScript Pro"`. The Async variant — the plain one is deprecated. Dock state restores itself via the persistent `pluginGuiId`.

**Toolbar:** `plugin:CreateToolbar("RoScript Pro"):CreateButton(...)` with `ClickableWhenViewportHidden = true` — without it the button greys out whenever a script tab has focus, which for a coding assistant is always. `button.Click` flips `widget.Enabled`; `widget:GetPropertyChangedSignal("Enabled")` → `button:SetActive(...)` keeps the X-close in sync.

**Layout tree** (hardcoded dark palette: bg `#111826`, panel `#1a2332`, accent `#8B4BCF`, text `#e5e7eb`; no theme-following in v1):

```
Root Frame
├─ TopBar (h=30): StatusLabel (flex) · CtxButton "CTX:ON" · GearButton
├─ ChatScroll: ScrollingFrame, AutomaticCanvasSize=Y, UIListLayout vertical
├─ InputBar (h=64): InputBox (single-line TextBox, ClearTextOnFocus=false) · SendButton / StopButton
├─ SettingsPanel (Visible=false, overlays ChatScroll)
├─ SourceModal (Visible=false): selectable read-only TextBox with a code block's full source
└─ PreviewModal (Visible=false): Run confirmation
```

- **Input:** `MultiLine=false` so Enter sends: `InputBox.FocusLost:Connect(function(enter) if enter then onSend() end end)` + `SendButton.Activated`. No `UserInputService` anywhere — documented not to work in widgets; GuiObject events only.
- **Bubbles:** `addBubble(role, text)`. Assistant text is split by `splitBlocks` on ``` fences: prose runs → RichText labels after `escapeRich`; code runs → `Enum.Font.Code` labels with RichText **off**, plus a button row **[Insert Script] [Run] [View]** followed by a small gray **target tag** — `→ ServerScriptService (Script)` — computed by `parsePlacement` when the block renders, so the Insert destination is visible *before* the click even when the model omitted the line-1 contract. Because selection can change between render and click, the Insert click **re-resolves placement fresh**; if the fresh result differs from the rendered tag, the first click only updates the tag (click again to insert) — the advertised destination is always the real one. `View` opens SourceModal — a selectable read-only TextBox, the copy affordance (**[unverified]** but near-certain: no clipboard-write API is listed anywhere in the Plugin/StudioService references). Labels cap at 16,000 chars; longer runs split into stacked labels. User bubbles carry a small gray caption when context was attached: `with context: 3 selected · Main (213 lines)`.
- **States:** IDLE → BUSY (`setBusy(true)`: input read-only, Send becomes **Stop**, temporary "Thinking…" bubble) → IDLE or ERROR (red status + error bubble with `[Retry]`). **StatusLabel contract:** IDLE → `Ready`; BUSY → `Thinking — <Provider> <model>` updated per queue entry; success → `Answered by <model>`; ERROR → the red failure line. `[Retry]` re-sends `lastPrompt` as a normal send — context is rebuilt fresh at that moment (§6's pull rule), never replayed. `busy` flag guards double-send. **Stop** = discard-on-arrival: it can't abort the yielded request, so it bumps the generation counter (§9), unbusies immediately, drops the eventual response, and **removes the stopped user message from history** (its bubble stays, marked "(stopped)") so the next send doesn't carry an unanswered turn.
- If spike 8 shows the known `AutomaticCanvasSize` glitch: manual `CanvasSize` from `UIListLayout.AbsoluteContentSize` changed-signal.

## 5. Provider port

**Chain** (fixed order; replaces the HTML app's complexity routing, vision branch, and daily tracker):

```lua
local PROV = {
  groq       = { name="Groq",       url="https://api.groq.com/openai/v1/chat/completions" },
  cerebras   = { name="Cerebras",   url="https://api.cerebras.ai/v1/chat/completions" },
  openrouter = { name="OpenRouter", url="https://openrouter.ai/api/v1/chat/completions" },
}
local MODEL_CHAIN = {
  {p="groq",       m="openai/gpt-oss-120b"},
  {p="groq",       m="openai/gpt-oss-20b"},
  {p="cerebras",   m="gpt-oss-120b"},
  {p="cerebras",   m="zai-glm-4.7"},
  {p="openrouter", m="openai/gpt-oss-120b:free"},
  {p="openrouter", m="openai/gpt-oss-20b:free"},
  {p="openrouter", m="nvidia/nemotron-3-super-120b-a12b:free"},
  {p="openrouter", m="meta-llama/llama-3.3-70b-instruct:free"},  -- known flaky, last resort
}
```

Thinking-mode models (`glm-4.5-air`, `nemotron-3-ultra`, `owl-alpha`) are cut: with no streaming and a timeout that can only be *shortened* (documented: `Timeout` "no greater than the default", default undocumented), hidden reasoning burns the wall clock. Same logic sets `reasoning_effort = "low"` (gpt-oss models only) and modest `MAXTOK = { groq=4096, cerebras=8192, openrouter=2048 }`. **Provisional entries:** `zai-glm-4.7` and `nemotron-3-super:free` are reasoning-family models with no effort control — they stay only if spike 4's timing shows no hidden-reasoning wall-clock burn; otherwise the same rule cuts them. Spike 4 finalizes the table; spike 9 prunes dead slugs. OpenRouter's attribution headers are literals in CONFIG: `HTTP-Referer = "https://github.com/jasper-0918/RoScript-Pro"`, `X-Title = "RoScript Pro"`.

**Rotation:** the HTML `KM` collapses to session-scoped `Cooling = {}` (`"groq:1" → os.clock()+secs`) and `Bad = {}`. `buildQueue()` walks `MODEL_CHAIN` × stored keys per provider, skipping bad/cooling. Per-send `failedModels` / `failedProviders` sets mirror the HTML behavior.

**Request** (`callProvider`): `RequestAsync{ Url, Method="POST", Headers={ ["Content-Type"]="application/json", ["Authorization"]="Bearer "..key, -- OR only: ["HTTP-Referer"], ["X-Title"] }, Body=JSONEncode{ model, messages, max_tokens, temperature=0.5, reasoning_effort } }`. No `stream`, no `tools`, no `Timeout` option.

**Response:** `Success` + `StatusCode==200` → `JSONDecode(Body)`. **A 200 body with no valid `choices` is inspected for `.error.code/.error.message` and classified through the normal table** (OpenRouter delivers moderation blocks and dead upstreams this way; treating them as "malformed → next" would never cool the key). Then `{ text=choices[1].message.content, truncated=(finish_reason=="length") }`. Empty content = failure, next entry.

**Continuation:** on `truncated`, exactly one extra round — **same entry first** (it just proved alive), then the fresh queue if that key errors — appending the partial as an assistant turn plus `"Continue exactly where you stopped. Do not repeat anything."`. Still truncated → gray footer "Response truncated."

**History:** in-memory only; last `HISTORY_MAX_MSGS=12` messages AND ≤ `HISTORY_MAX_CHARS=15000` total (drop oldest until both hold). The char cap is quota-driven, not timeout-driven: free tiers meter tokens-per-minute and per-day, so a smaller history roughly doubles session length per key at negligible answer-quality cost. Context blocks are never stored in history (§6).

**System prompt** (`SYS_BASE` port): Roblox/Luau identity only (Unity/UE5/C/JS paragraphs dropped), the 7 ROBLOX STRICT RULES verbatim, a 3-line Deep-Think paragraph, RESPONSE LENGTH (feeds the continuation round), EFFICIENCY, plus two plugin paragraphs: (a) `STUDIO CONTEXT` blocks describe the live place and are ground truth; (b) the Run contract — *"Code meant for the Run button must be straight-line edit-time code: no yielding, no event connections, no `task.spawn`/coroutines, no long loops. Anything long-lived or event-driven must be a complete script for Insert instead."* — the safety boundary is told to the model at generation time, not only to the human in the preview warning; (c) the Insert contract with its path grammar spelled out for the model — *"Every complete script starts with `-- SCRIPT: <Name> | <Script|LocalScript|ModuleScript> | <ParentPath>` on line 1, inside a ```lua fence. ParentPath is dot-separated instance Names from the top of the game, no `game.` prefix — e.g. `ServerScriptService` or `ServerScriptService.Systems`."* `buildSystemPrompt()` = `SYS_BASE` + skill append **iterating the canonical `SKILLS` definition order filtered by the active set** (never iterating the active set itself — `pairs` order would break byte-identity) — **byte-identical for the same active-skill set, never a timestamp** (ported caching rule: providers prefix-cache the system prompt).

**Refusal note:** response < 400 chars matching any of a **list of Luau patterns** tried in order against `text:lower()` (`"i can'?t"`, `"i cannot"`, `"i'm sorry"`, `"i am unable"`, `"cannot assist"`) → gray footer "Looks like a refusal — rephrase or hit Retry." No auto-retry, no loop. (**Convention for the whole spec:** every match expression written here with `|` is prose shorthand for a Lua table of individual patterns tried in order with `string.find` on the lowercased subject — Luau patterns have no alternation.)

## 6. Context builder

`buildContext()` → string or nil. **Pull-based, at send time only** — no `SelectionChanged`/`ActiveScript` listeners.

```
=== STUDIO CONTEXT BEGIN ===
Selection (3 of 3):
- workspace.Enemies.Zombie | Model | 14 children: Humanoid (Humanoid), ...
- workspace.SpawnPad | Part | Size 4,1,4 | Pos 12,0.5,-3
Active script: ServerScriptService.Main (Script, 213 lines)
<editor source, size-capped>
=== STUDIO CONTEXT END ===
```

- **Sentinel lines, not ``` fences** — a script containing backticks would break a fenced payload.
- **Selection** (`Selection:Get()`, first 20, `(20 of N)` header): per instance `GetFullName() | ClassName |` extras — BasePart: rounded Size/Pos; Model/Folder: child count + first 8 `Name (Class)`; LuaSourceContainer: line count. Block cap 2,000 chars.
- **Active script:** `StudioService.ActiveScript` (nil-safe) → `ScriptEditorService:GetEditorSource()` in pcall. There is **no** `ActiveScriptDocument` API — `StudioService.ActiveScript` is the verified route. Never read `.Source` for open scripts.
- **Caps:** script 8,000 chars (first 6,000 + `-- [... middle truncated ...]` + last 2,000), whole block `CTX_MAX=11,000` — deliberately above the component caps (2,000 + 8,000) plus sentinel/header overhead; if the assembled block still exceeds it, **the script tail is trimmed first**, utf8-snapped. **Every cut snaps to `utf8.offset` boundaries** — a mid-multibyte slice produces invalid UTF-8, which can corrupt or reject the JSON-encoded send (design assumption; snapping is correct defensive practice regardless of `JSONEncode`'s exact failure mode).
- **Assembly:** context is appended to the **outgoing copy** of the newest user message only; `history` stores bare text. Keeps history small and the cached system-prefix stable.
- **Toggle:** `CtxButton` flips `ctx_enabled` (default true). The user bubble's caption (§4) is the audit trail for what was attached.

## 7. Insert & Run

**Insert as Script** — one click, no modal:
1. `parsePlacement(code)`: line-1 contract `-- SCRIPT: Name | Class | ParentPath`. Fallback heuristics when absent: `LocalPlayer|UserInputService|ContextActionService` → LocalScript → StarterPlayerScripts; `^%s*local%s+%w+%s*=%s*{}` + trailing `return` → ModuleScript → ReplicatedStorage; else Script → ServerScriptService.
2. Parent resolution — precedence is explicit: **selection override > contract path > class fallback.** Selection override applies only when **exactly one** instance is selected **and** its class is in the container whitelist `{Folder, Model, Workspace, ServerScriptService, ServerStorage, ReplicatedStorage, StarterGui, StarterPack, StarterPlayerScripts, StarterCharacterScripts, Tool}` — a deliberate user gesture wins; never parent a script under a script. Contract path: `parsePlacement` strips a leading `game.`, aliases `workspace` → `Workspace`, then walks from `game` with `FindFirstChild` per dot-separated segment — **never** instantiate or trust a model-supplied path beyond lookup; unresolvable → the class fallback parent. The resolved destination is what the block's target tag (§4) displays.
3. `TryBeginRecording("RoScriptPro Insert")`; **nil → refuse** (status: "Undo unavailable (playtest running?) — not inserting").
4. `Instance.new(class)` → `.Name` → `.Source = code` (new instance, not open in an editor — `UpdateSourceAsync` is for already-open documents) → `.Parent`. The `.Source` and `.Parent` writes are pcall-wrapped: a failure mentioning permission → status **"Enable Script Injection for RoScript Pro in Plugin Management, then retry"**. (**[unverified]**: the Script Injection permission gate is community knowledge, not in the facts research — spike 3 exists precisely to observe the real behavior and set this copy.)
5. **Recording disposition on every path:** any step-4 failure → `FinishRecording(recId, Enum.FinishRecordingOperation.Cancel)` + red status, nothing half-inserted. Success → `FinishRecording(recId, Commit)` → `OpenScriptDocumentAsync(s)` in pcall → status "Inserted ServerScriptService.Name".

**Run in Studio** — preview-gated, runs once:
- `[Run]` opens PreviewModal: the exact code read-only, warning *"Runs immediately at edit time. One undo step. Yielding code may outlive the undo recording."*, buttons `[Run once]` (disables itself after firing) and `[Cancel]`.
- Engine = spike 2's winner (naming matches the spike: **loadstring** preferred if both pass; **module-require** otherwise; neither → Run is cut and v1 ships Insert-only). The module-require shape, with the disposition rule applied:

```lua
local recId = ChangeHistoryService:TryBeginRecording("RoScriptPro Run")
if not recId then UI.setStatus("Undo unavailable — refusing to run", true) return end
local okBuild, mod = pcall(function()
  local m = Instance.new("ModuleScript")
  m.Name = "_RoScriptProRunner"
  m.Source = "return function()\n" .. code .. "\nend"   -- Script Injection gate can throw here
  m.Parent = game:GetService("ServerStorage")
  return m
end)
if not okBuild then
  ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Cancel)
  UI.setStatus("Enable Script Injection for RoScript Pro in Plugin Management, then retry", true)
  return
end
local okC, fnOrErr = pcall(require, mod)          -- compile errors surface here
local okR, runErr = false, nil
if okC and type(fnOrErr) == "function" then okR, runErr = pcall(fnOrErr) end
mod:Destroy()
-- User code never ran → Cancel (nothing to keep). User code ran at all → Commit,
-- even on a runtime error: partial changes stay visible and undoable (spike 7 may refine).
local op = okC and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
ChangeHistoryService:FinishRecording(recId, op)
```
- Errors: compile → red line under the block "Syntax error: …"; runtime → "Runtime error: …"; both also `warn("[RoScript Pro] …")` for the full trace in Output. Success → green "Ran OK (undo: Ctrl+Z)".
- Run executes synchronously in the plugin thread inside pcall — long/yielding code blocks Studio and post-yield changes can escape the recording; the preview warning owns this. Run targets edit-time utilities (spawn parts, batch renames); game logic gets **Insert**.

## 8. Settings & keys

- `S.get/S.set`: in-memory cache over `plugin:GetSetting/SetSetting`. All known keys read once at load; `S.get` prefers cache when GetSetting returns nil (documented: multi-window sessions make reads silently nil). `S.set` writes cache first, then pcall-SetSetting. Last-writer-wins across windows is accepted for a single-user tool.
- **Keys:** `keys_groq` / `keys_openrouter` / `keys_cerebras`, stored as arrays of strings — **but the docs say arrays round-trip as string-keyed maps** ("Arrays are automatically converted to maps by converting the numeric keys to strings first"), so `KeyStore.load` normalizes on read: accept a numeric array OR a map with keys `"1".."n"` and rebuild the array; a naive `ipairs` read would silently lose every key after a restart. `KeyStore.add` trims, rejects empties, duplicates, and any value containing `\` or `"` (e.g.-list — the docs warn certain characters corrupt the settings file without enumerating them). Setting names stay alphanumeric+underscore. **Chat text is never written to settings** (corruption risk + no history browser in v1).
- Other settings: `ctx_enabled` (default true), `active_skills` (default `{}`).
- **SettingsPanel:** per provider — masked key rows (`groq #1 ····a3f9`) with `[x]`, TextBox + `[Add]`; skill-pack checkboxes; `[Clear conversation]`; footer: *"Keys are stored in plain text in Studio's plugin settings on this machine. Personal use only."*
- **Skill packs (7, near-verbatim from `DEFAULT_SKILLS`, emoji stripped):** rblx-datastore, rblx-anticheat, rblx-remotes, rblx-combat, rblx-ui, general-clean, general-debug. Unity, algo, patterns, security-tester dropped.

## 9. Error handling & reload safety

`classifyFailure(entry, resp, pcallErr)` — port of the HTML `handleError`:

| Signal | Action |
|--------|--------|
| pcall on RequestAsync failed | cool key 15s, next; message mentioning permission/"not allowed" → status "Studio blocked the request — check Plugin Management" |
| 429 or `rate.?limit|quota|too many` | `Cooling[key] = os.clock() + (Retry-After or body match or 30)`, next |
| 401/403 or `invalid.api.key|unauthorized` | `Bad[key] = true`, next |
| 404 / `model_not_found|no endpoints|unavailable` | `failedModels[p..":"..m]` for this send, next |
| 400 `request too large|context_length|too many tokens` | `failedProviders[p]` for this send, next |
| 400 naming `reasoning_effort` (if spike 5 fires) | retry same entry once with the field stripped; remember per-provider for the session |
| 200 with `.error` body / no choices | classify `.error.code/.message` through this same table; only then "malformed → next" |
| JSONDecode failure / empty content | generic failure, next |

- Queue exhausted → error bubble, one line per provider ("Groq: 2 keys cooling ~28s") + `[Retry]`. No keys at all → "Add a free Groq/OpenRouter/Cerebras key in Settings."
- `escapeRich(s)`: `&`→`&amp;` first, then `<`→`&lt;`, `>`→`&gt;`, applied to every prose run before a RichText label. Code labels are RichText-off, raw.
- Every throwing Roblox call (`GetEditorSource`, `OpenScriptDocumentAsync`, `require`, `SetSetting`, `RequestAsync`, `JSONDecode`) is pcall-wrapped; failures degrade to a status line, never a dead panel.
- **Generation counter (reload/stop safety):** `gen` increments on every send, on Stop, and on `plugin.Unloading`. Async work captures `myGen = gen` and, **after every yield**, re-checks `myGen == gen` and widget liveness before touching UI or history. This is what makes the Ctrl+Shift+L dev loop safe with a ~30s request in flight, and it is Stop's entire mechanism.

## 10. Dev / install loop

- Source of truth: `studio-plugin/RoScriptPro.lua`; edit in VS Code.
- Install/update: `Copy-Item "studio-plugin\RoScriptPro.lua" "$env:LOCALAPPDATA\Roblox\Plugins\"` — path is community knowledge **[unverified]**, spike 1 confirms; documented fallback is *Save as Local Plugin* from a Script in Studio.
- Reload: enable **Plugin Debugging Enabled** once; after each copy, `PluginDebugService → Save and Reload Plugin` (or Ctrl+Shift+L reload-all). **No hot-reload exists** (verified); without plugin debugging it's a Studio restart per edit.
- Local plugins reportedly bypass HTTP permission prompts entirely (DevForum, spike 6) — so the permission dialog never gates daily use; the classify-table message covers the published-copy case if that ever happens.
- `DEV=true` gates `print("[RSP]", …)` tracing: queue order, status codes, context sizes.

## 11. Manual test checklist (per sitting, no automation pretense)

A Studio plugin has no honest CI here; verification is a scripted manual pass:
1. Fresh Studio, plugin loads, widget toggles from toolbar with a script tab focused (ClickableWhenViewportHidden).
2. No keys → helpful message. Add Groq key → send "hello" → answer renders; StatusLabel walks its §4 contract (`Thinking — Groq openai/gpt-oss-120b` → `Answered by openai/gpt-oss-120b`).
3. Select 3 instances + open a script → send → user bubble caption shows both; `DEV` trace shows caps respected; script with emoji near the cap still sends (utf8 trim).
4. Ask for a full script → line-1 contract present → Insert lands in the right service, one Ctrl+Z removes it, editor opens it.
5. Run a part-spawning snippet → preview → run → part exists → Ctrl+Z removes it. Syntax-broken snippet → red compile error, nothing created.
6. Kill the network → send → per-entry failures walk the chain → clean exhausted message → Retry works after network returns.
7. Ctrl+Shift+L mid-request → no errors in Output, response silently discarded (generation counter).
8. Restart Studio → keys and toggles survived **and keys still read back as a proper list** (the documented array→map settings conversion is the trap this exercises); once during the build, a two-window sanity check (add a key in each window, restart both, confirm nothing was lost beyond last-writer-wins).

## 12. Deliberately NOT in v1

Web search/Tavily · image gen/vision · artifacts panel · chat persistence/history browser · streaming (`CreateWebStreamClient` = **v2 candidate** once verified in plugin context) · multi-round continuation · sandbox self-check · refusal auto-retry · complexity-based routing · daily usage counters · custom skill editor UI · Studio-theme following · live context chips/listeners · clipboard buttons (no API — View modal is the copy path) · multiline composer · localhost companion relay · settings import/export · Creator Store publishing.

**The v1.5 line** (first follow-ups, in order — the council was unanimous that these two close the loops v1 half-closes): ① `UpdateSourceAsync` **patch-into-open-script** — most real asks are edits to the script already open, and v1 automates that flow's read half only; ② **recent Output/error-lines context** — the run-game → error → ask loop is the one that actually drove past the built-in Assistant's cap, and v1 still hand-copies the error text.

## 13. Verified-facts appendix (checked 2026-09-02)

| Fact | Status | Source |
|------|--------|--------|
| `CreateDockWidgetPluginGuiAsync` supersedes deprecated `CreateDockWidgetPluginGui`; same params; id persists dock state | verified | create.roblox.com/docs/reference/engine/classes/Plugin |
| Standard GuiObjects work in widgets; `UserInputService` does not | verified | …/docs/studio/build-studio-widgets |
| `PluginToolbarButton.ClickableWhenViewportHidden` needed for script-tab focus | verified | …/classes/PluginToolbarButton |
| `RequestAsync` from plugins: POST + custom headers incl. Authorization | verified | …/cloud-services/http-service |
| Plugin HTTP permission = per-plugin per-domain prompt, managed in Plugin Management | verified | …/cloud-services/http-service |
| Local plugins bypass the permission prompt; `HttpEnabled` gates only in-game | **unverified** (official DevForum announcement only) | devforum…/introducing-plugin-http-permissions/493269 |
| `Timeout` option can only shorten; default timeout undocumented; 500 req/min | verified | …/classes/HttpService#RequestAsync |
| Exceeding limits "can cause request-sending methods to stall for around 30 seconds" | verified | …/cloud-services/http-service |
| `CreateWebStreamClient` exists: SSE + raw streaming, 6-client cap; plugin-context behavior unstated | verified (existence) | …/classes/HttpService#CreateWebStreamClient |
| `Selection:Get()` + `SelectionChanged` (event carries no payload) | verified | …/classes/Selection |
| No `ActiveScriptDocument`; active script = `StudioService.ActiveScript` → `FindScriptDocument`/`GetEditorSource` | verified | …/classes/ScriptEditorService, …/classes/StudioService |
| `.Source` direct edit discouraged for open scripts; `UpdateSourceAsync`/`GetEditorSource` are the editor-safe APIs | verified | …/classes/Script, …/classes/ScriptEditorService |
| `TryBeginRecording`/`FinishRecording` current; nil id when recording impossible; `SetWaypoint` legacy | verified | …/classes/ChangeHistoryService |
| `loadstring` in plugin context | **unverified** (docs silent; DevForum conflicting) — spike 2 | …/globals/LuaGlobals |
| `ModuleScript` + `require` executing model code at edit time (the module-require Run engine, incl. module-cache behavior) | **unverified** (community pattern, not researched in docs) — spike 2 | — |
| Script Injection per-plugin permission gating `.Source` writes | **unverified** (community knowledge, zero doc coverage found) — spike 3 | — |
| No clipboard-write API for plugins (View modal is the copy path) | **unverified** (asserted from absence in Plugin/StudioService references) — no spike needed, worst case is a redundant modal | — |
| Local `.lua` drop-in + `%LOCALAPPDATA%\Roblox\Plugins` path | **unverified** (Save-as-Local-Plugin is the documented flow) | …/docs/studio/plugins |
| No hot-reload; `PluginDebugService → Save and Reload` is the documented loop | verified | …/docs/studio/plugins |
| `Get/SetSetting`: JSON-encodable, persists; multi-window reads can silently nil; certain chars corrupt the settings file | verified | …/classes/Plugin |
| No documented secret storage for plugins; settings are plaintext JSON on disk | **unverified** location (DevForum), silence on secrets is verified — no spike needed, the design assumes worst-case plaintext | …/classes/Plugin |
| `TextBox.MultiLine`/`ClearTextOnFocus`; `RichText` tags + escape rules; no `<code>` tag | verified | …/classes/TextBox, …/docs/ui/rich-text |
