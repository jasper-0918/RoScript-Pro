# RoScript Pro Studio Plugin v2 — Goal Mode design

**Date:** 2026-09-03 · **Revision:** 2 (after the 8-finder adversarial gauntlet; rev 1 is commit `978f2de`) · **Status:** spec pending Jasper's review · **Base:** v1 plugin on `main` (`17db5c6`), spec `2026-09-02-roscript-studio-plugin-design.md`

Goal Mode turns the v1 chat shell into an in-Studio assistant that can see the whole workspace, plan a change, carry it out across files, verify by running the game, and remember what it did so the next plan starts from a summary instead of a transcript. It is a bounded plan → act → verify → record cycle with Jasper between cycles, not an unattended loop. The unattended loop stays with Claude Code + Roblox's Studio MCP server, which has screenshots and Play-with-character that a plugin cannot get.

**What rev 2 changed, in one paragraph.** The gauntlet found that `RunService:Stop()` does not restore the place (only the Stop *button* does), so VERIFY is now driven by Jasper pressing Run and Stop while the plugin captures. `GetDebugId` refs would have collided, so refs are plugin-assigned. Strict tool schemas cannot carry free-form maps, so `props` travels as name/value pairs. Free-tier per-minute limits would have killed most plans mid-step, so the loop now waits out short cooldowns and paces Cerebras. `UpdateSourceAsync` yields, so the recording invariant is restated around it. The record write lands on top of the undo stack, so RECORDING is exactly one undo entry and the UI says so. Plus the revert button, the manifest, `read_output`, `replace_lines`, multi-target writes, and an effort setting for when tokens are cheap.

---

## 1. Settled decisions (from the 2026-09-03 brainstorm; D5 amended in rev 2)

| # | Decision | Chosen |
|---|---|---|
| D1 | Agent architecture | **Native OpenAI-style tool calling** inside the plugin. All three providers speak it (appendix A1, A5, A7). Text-protocol and one-shot apply-script approaches rejected. |
| D2 | Act gating | **Approve the plan once.** Prompt only before destructive or off-plan writes (§8.4). A `Careful` setting makes every write prompt. |
| D3 | Context store | **`ServerStorage.RoScriptPro`**, saved with the place. Per-place by construction; ServerStorage never replicates to clients. Capped (§4.5) because it also publishes with the place. |
| D4 | Deletes | **The model never `Destroy`s.** `trash(target)` moves into the store's Trash with the original parent recorded. Only Jasper's confirmed Empty Trash destroys. |
| D5 | Verification | **Run-button verification** (rev 2): the plugin arms capture and asks Jasper to press Run (F8) then Stop; it never calls `RunService:Run()` or `Stop()` itself, because the *method* does not restore the place and the *button* does (A9, A15). One budgeted repair pass on errors that name a changed script. |
| D6 | File shape | **Still one file** (`studio-plugin/RoScriptPro.lua`); drop-in install is the point. Goal Mode lands as four new banner sections with hard boundaries (§14). A split-source build is noted for v3 (§16). |
| D7 | Scope | One goal at a time. "Plan next" starts a new cycle from memory. No multi-plan queue. |
| D8 | Spend | $0 rule unchanged. Free tiers, keys in plugin settings, never in the repo. |

---

## 2. Spike checklist — run in Studio before coding (gates the build)

Throwaway plugin `RSP_Spikes2.lua` in `Downloads\Personal\`, pasted into `%LOCALAPPDATA%\Roblox\Plugins`, prints `[RSP SPIKES2] Sn PASS|FAIL detail`. **Delete it after** (it carries a pasted key for S5/S6). One Studio sitting.

| Spike | Question | Pass criterion | On FAIL |
|---|---|---|---|
| **S1** | `ScriptEditorService:UpdateSourceAsync` inside a `TryBeginRecording` recording: does it land in undo, for an unopened script and for an open document? Does it yield (set a flag in a one-shot `Heartbeat` before the call, read it after)? If it yields, what does `FinishRecording(Cancel)` issued during the yield leave behind? | Both cases: source changes, one Ctrl+Z entry reverts it, the open editor buffer reflects it. Record yield yes/no and the cancel-during-yield outcome. | Unopened scripts: write `.Source` directly (synchronous, v1 path). Open documents: keep `UpdateSourceAsync` with the §8.3 yield rule. |
| **S2** | Does `LogService.MessageOut` fire in the **plugin** context during a Run-button playtest, for a Script that prints then errors? Fallback check: with Output pre-filled past 512 lines, does the post-Stop `GetLogHistory()` timestamp diff (§9.3) still contain both lines? | Plugin receives the print and a `MessageType.MessageError`; the fallback diff also contains both. | Primary FAIL: use the fallback only. Fallback FAIL: `verify.overflowed` semantics (§9.3) apply always and capture is best-effort. |
| **S3** | Across a Run-button playtest (Run, wait 5 s, Stop): does a recorded edit committed *before* Run still undo *after* Stop; do plugin-held instance references and `Refs` entries captured before Run still resolve after; does `TryBeginRecording` work again after Stop; does `IsRunning()` go true then false and `IsEdit()` the inverse? | All four yes. Also record the observed `IsRunMode()` value during the button run (expected true). | Undo lost: VERIFY ships default-off and its setting text says undo of the plan is lost once a run has happened. Refs lost: REPAIRING re-resolves every target by path before writing. |
| **S4** | Confirm chunk sizes against the documented 200,000-char `StringValue` cap (A13). | 100,000 and 150,000 chars write and read back equal. | `CHUNK_MAX` drops to 50,000. |
| **S5** | Send the **exact production request body** (§6.1, §6.2) to each provider: the full Goal tool set including an arg-less tool (`read_memory` with its `reason` field), `parallel_tool_calls`, `temperature 0.2`, `reasoning_effort=low`, `strict=true` where the provider flag says so, `require_parameters=true` on OpenRouter. Round-trip one `tool` message and the assistant's `reasoning` field. First step for OpenRouter: `GET /api/v1/models/{id}/endpoints` for each `:free` gpt-oss variant. | 200 with a well-formed `tool_calls[1].function.{name,arguments}` (arguments a JSON string) on every provider tried; the tool-message follow-up returns 200; a 400 naming `strict` or an unknown parameter is recorded per provider. Empty `endpoints` marks that OpenRouter entry dead for Goal. | 400 on `strict`: that provider's `strictTools=false`. 400 on any other parameter: drop it for that provider. Still failing: that provider's entries get `tools=false`. |
| **S6** | Send one request of ~10K input tokens on a Groq free key. Record status, body, whether the body matches `PAT_RATELIMIT` and `PAT_TOOLARGE`, and the body's "Requested N" figure against the known input size. | Records exist. If Requested ≈ input + `max_tokens`, Groq counts `max_tokens` toward the TPM check. | Requested includes `max_tokens`: `GROQ_REQ_MAX = 8000 - GOAL_MAXTOK.groq` (= 3,904 with the §6.2 defaults). Body matches neither pattern list: add its wording to `PAT_TOOLARGE`. |

**Build order gate:** S1 and S5 gate ACT. S2 and S3 gate VERIFY. S4 gates the chunk size. S6 sets `GROQ_REQ_MAX`.

---

## 3. The cycle

```
IDLE ──Plan──▶ PLANNING ──submit_plan──▶ AWAITING_APPROVAL ──Approve──▶ ACTING(step 1..n)
  ▲                                            │ Revise ─▶ PLANNING (same transcript + note)  │
  │                                            │ Cancel ─▶ RECORDING(status=cancelled)        ▼
  │                                                          all included steps done? ──yes──▶ VERIFYING (if enabled, Jasper presses Run/Stop)
  │                                                                     │ no                          │ errors on changed scripts ─▶ REPAIRING (one pass) ─▶ Jasper runs again
  └──────────────────────── RECORDING ◀────────────────────────────────┴─────────────────────────────┘
```

- **Stop** (button) from any non-idle state: bump `gen`; the owning batch coroutine cancels its own recording at its next check (§8.3); disconnect `MessageOut` if connected; if the plan had reached ACTING, go to RECORDING with `status="stopped"`; a Stop before `submit_plan` writes no record. The plugin never calls `RunService:Stop()` (D5); if Jasper is mid-playtest the RECORDING write waits for `IsEdit()` (§4.1).
- **Plugin unload** mid-cycle: bump `gen`, cancel any recording this plugin opened, disconnect connections, clear `Refs`. No store write (no yields in `Unloading`). Cleanup is exempt from the generation rule and runs before anything else.
- Each state has its own tool set (§5), message seeding (§7, §8), and budgets (§6.3).
- **Plan next** is PLANNING with an empty goal; the model proposes improvements along the ticked focus chips (§7.1).

---

## 4. Context store

### 4.1 Layout and write rules

```
ServerStorage
└─ RoScriptPro                     Folder   attrs: RSP_StoreVersion=1
   ├─ Memory                       Folder   → chunk_1..n (StringValue)   §4.2
   ├─ Manifest                     Folder   → chunk_1..n (StringValue)   JSON { path → hash } for every LuaSourceContainer, written at RECORDING
   ├─ Plans                        Folder   (newest 20 kept, §4.5)
   │   └─ Plan_001_add-shop-ui     Folder   attrs: RSP_Status, RSP_CreatedAt, RSP_Goal(≤200)
   │       ├─ chunk_1..n           StringValue   JSON plan record (§4.3)
   │       └─ before/<k>           Folder → chunk_1..n   pre-write source of changed script k (§4.4 Revert)
   └─ Trash                        Folder   (25 items / 14 days, §4.5)
       └─ <moved instances>        attrs: RSP_OrigParent, RSP_OrigName, RSP_Plan, RSP_TrashedAt
```

- Created lazily on the first PLAN. If `ServerStorage.RoScriptPro` exists with a **different** `RSP_StoreVersion`, Goal Mode refuses to start and says so; no silent migration in v2.
- **Chunking:** text is split at `CHUNK_MAX = 100000` chars (S4 confirms; the documented cap is 200,000, A13) into `chunk_1..n`; readers concatenate in numeric order; writers create/overwrite then delete surplus `chunk_k`, k>n.
- **Store writes happen only in edit mode.** `Store.write*` refuses while `not RunService:IsEdit()` and the caller retries on the next `Heartbeat` where `IsEdit()` is true (gen-checked). RECORDING therefore always runs after Jasper has pressed Stop.
- **One recording per RECORDING.** Memory, Manifest, the plan record, its `before/` chunks and the folder attributes are written inside a single `RoScript Pro: record` recording, so RECORDING adds **exactly one** undo entry. That entry sits on top of the step entries: the first Ctrl+Z after a cycle removes the record and Memory rewrite, the next ones revert step batches in reverse order. The result card says so (§10) and the Plans list refreshes on `ChangeHistoryService.OnUndo`/`OnRedo` so an undone record never leaves a stale row.
- The store is **protected**: write tools (§5.2) refuse any target under `ServerStorage.RoScriptPro`, except `trash()` moving *into* Trash and Restore/Empty Trash acting on Trash. Read tools may index it (the model is told what it is).

### 4.2 Memory

Two blocks, both replaced (never appended) at RECORDING, total ≤ `MEMORY_MAX = 6000` chars:

1. **Facts** (plugin-generated, deterministic, ≤ 2,500 chars): top-level services with child counts, every script the store has ever seen changed with its path and current hash, scripts whose Manifest hash no longer matches (`edited outside Goal Mode`), Trash count, last three plan ids with status.
2. **Notes** (model-written via `write_memory`, ≤ 3,500 chars) under fixed headings: `Game`, `Conventions`, `Decisions`, `Known issues`. If the model returns more, the plugin trims at a paragraph boundary and appends `[trimmed]`.

The facts block exists so a hallucinated path in Notes cannot compound: PLANNING sees both and is told Facts wins on conflict.

### 4.3 Plan record (JSON, one per cycle)

```json
{
  "v": 1,
  "id": "Plan_003_fix-shop-errors",
  "status": "done | partial | failed | stopped | cancelled",
  "createdAt": 1756900000,
  "goal": "…",                       "focus": ["bugs","quality"],
  "plan": { "title": "…", "summary": "…", "verify_hint": "…",
            "steps": [ { "n":1, "title":"…", "action":"edit", "targets":["ServerScriptService.Shop"],
                         "detail":"…", "risk":"low", "included":true } ] },
  "revisions": [ { "plan": { "...prior submit_plan object..." }, "note": "…", "at": 1756899000 } ],
  "steps": [ { "n":1, "status":"done | failed | skipped | stopped", "outcome":"…",
               "changed":[ { "path":"…", "ref":"#r17", "kind":"script | instance",
                             "hashBefore":"9f3e…", "hashAfter":"01cc…", "before":"before/1",
                             "origParent":"Workspace.Lobby" } ],
               "writes":[ { "tool":"replace_lines", "from":40, "to":52, "newLines":13 },
                          { "tool":"edit_script", "find":"…", "replace":"…" } ],
               "undoLabels":["RoScript Pro: Step 1"] } ],
  "verify": { "enabled":true, "ran":true, "overflowed":false, "errors":["…"], "preexisting":["…"], "warnings":2,
              "output":["first 60 lines…"],
              "repair": { "ran":true, "outcome":"…", "changed":[], "undoLabels":["RoScript Pro: Repair"], "errorsAfter":[] } },
  "models": ["cerebras/gpt-oss-120b"], "estTokens": 41000,
  "summary": "≤ 2000 chars, model-written at RECORDING"
}
```

- `status`: `done` = every included step done; `partial` = at least one step failed or stopped after at least one done; `failed` = zero steps done; `stopped` = Stop pressed; `cancelled` = Cancel on the plan card. `RSP_Status` mirrors it.
- `id` = `Plan_` + zero-padded sequence + `_` + slug of the plan title (≤ 30 chars, `[a-z0-9-]`).
- **Hashes** are FNV-1a 32-bit over the script source as read by §5.0, hex, implemented with `bit32` in STORE. `hashBefore`/`hashAfter` exist only for `kind="script"`. `index` compares each script's current hash with the **Manifest** written at the last RECORDING and emits `changed-since-plan` (touched by a plan) or `edited-outside` (Manifest mismatch with no plan write), so PLANNING knows what moved since it last looked.
- `writes[]` persists what each step actually did (capped at 4,000 chars per step, `replace`/`find` trimmed first) so `read_plan` and Plan next see real edits, not just "Shop changed".
- `revisions[]` keeps every plan Jasper revised away, with his note, so "context for each plan made and changed" is literal.
- `PLANS_FED_TO_PLAN = 3`: PLANNING is seeded with the `summary` of the three most recent records plus the `status`/`outcome` lines of any `failed` or `stopped` steps and the most recent record's revision notes.

### 4.4 Trash, Restore, Revert

- **`trash(target)`** sets `RSP_OrigParent` (the parent's full name), `RSP_OrigName`, `RSP_Plan`, `RSP_TrashedAt`, then reparents into `Trash`, inside the step's recording (Ctrl+Z restores it too).
- **Restore** (Trash view, per item) runs under a `RoScript Pro: restore` recording: reparent to `RSP_OrigParent` if it resolves, else `Workspace`; if a sibling named `RSP_OrigName` already exists there, prompt: rename with `_restored` or replace. Clears the four attributes.
- **Empty Trash**: one confirm modal, then `Destroy` each child under a `RoScript Pro: empty trash` recording. The only `Destroy` in the design, and it is Jasper's click.
- **Revert plan** (result card and Plans view): restores every `changed[]` entry of that record under one `RoScript Pro: revert Plan_NNN` recording. Scripts: write `before/<k>` back **only if** the current hash equals `hashAfter` (untouched since), otherwise skip that file and list it. Moves and trashes: reparent to `origParent`. Creates: trash them. Revert is the safety net that survives the undo history and a new Studio session.

### 4.5 Caps

The store publishes with the place, so it is bounded: Trash keeps the newest 25 items and nothing older than 14 days (oldest auto-emptied at RECORDING with a status line); Plans keeps the newest 20 records (oldest pruned at RECORDING, `before/` chunks with them). The Goal view shows `Trash (n)` and an estimated store size next to `Plans`.

---

## 5. Tools

Every tool is a Luau function `(args) -> resultTable`. Results are JSON-encoded as the `tool` message content. Failures return `{ ok = false, error = "…" }` to the model; they never throw into the loop. An unknown tool name, or a tool outside the current phase's set, returns `{ok=false, error="no tool named X in this phase; available: …"}` under that call's `tool_call_id`, counts toward `MAX_CONSECUTIVE_TOOL_ERRORS`, and is logged (Cerebras documents that gpt-oss-120b invents tool names).

### 5.0 Target resolution and source reads

- `target` accepts a full path (`ServerScriptService.Shop`) or a **ref** (`#r17`). Refs are **plugin-assigned** from a session counter the first time an instance is emitted by `index`/`inspect`/`search`/`read_output`, kept in a session-scoped `Refs` map (`ref → instance`, cleared on unload). Uniqueness is by construction; `GetDebugId` is not used (its first characters are a shared scope prefix, so truncating it collides; A11). A ref resolves only if `Refs[ref]` exists **and** `inst:IsDescendantOf(game)`; otherwise the recorded path is tried, then `{ok=false, error="ref stale and path did not resolve"}`. Paths resolve via v1's `walkPath`; when siblings share a name the first match wins, which is why refs exist. Plan records store both; a new session resolves by path.
- **Every source read** (`read_script`, `search`, `index` line counts, hashes, the `replace_lines` anchor, and `edit_script`'s find) uses `ScriptEditorService:GetEditorSource(script)` in pcall and falls back to `.Source`, so an open editor with unsaved changes is what the model sees and edits.

### 5.1 Read tools (every phase except RECORDING)

| Tool | Args | Returns | Caps |
|---|---|---|---|
| `index` | `path` (default `game`), `depth` (1–3, default 2) | lines `name | class | children | lines(if script) | changed-since-plan / edited-outside | #ref` | `INDEX_MAX_ENTRIES = 200` per call, then `…N more, narrow the path` |
| `inspect` | `target` | whitelisted properties (§5.4), attributes, tags, children summary | one instance |
| `read_script` | `target`, `fromLine`, `toLine` (nullable) | numbered source slice, `totalLines`, `hash` | `READ_SCRIPT_MAX = 8000` chars per call; the model pages |
| `search` | `text`, `root` (default `game`), `pattern` (bool, default false) | `path:line: text` hits | plain case-insensitive substring by default (`string.find(…, 1, true)`); `pattern=true` opts into Luau patterns inside pcall (a malformed pattern is a tool error, not a throw); `SEARCH_MAX_HITS = 40`, lines trimmed to 160 chars |
| `read_output` | `count` (default 40) | the newest `MessageError`/`MessageWarning` entries from `LogService:GetLogHistory()`, newest first, each trimmed to 200 chars, with the script path when the message names one | 4,000 chars |
| `read_memory` | `reason` | Facts + Notes | – |
| `list_plans` | `offset` (default 0) | `id · status · createdAt · goal(≤120)`, 10 per page | – |
| `read_plan` | `id` | the plan record JSON (with `writes[]`) | – |

`index` skips `CoreGui`, `Chat`, `TextChatService` internals and camera/terrain children, and labels `ServerStorage.RoScriptPro` as `[RoScript Pro store]`.

### 5.2 Write tools (ACTING and REPAIRING only)

| Tool | Args | Effect | Guard |
|---|---|---|---|
| `replace_lines` | `target`, `fromLine`, `toLine`, `expectHash`, `newText` | replace an inclusive line range | fails if `expectHash` ≠ the current hash (source moved since the model read it) |
| `edit_script` | `target`, `find`, `replace`, `all` (bool) | plain-text find/replace computed **inside** the `UpdateSourceAsync` callback on the source it receives | not found → `{ok=false, error="find not found", nearest="±3 numbered lines around the best single-line match"}`; found more than once with `all=false` → count and line numbers |
| `write_script` | `target`, `source` | replace whole source | destructive prompt per §8.4 |
| `create` | `class`, `parent`, `name`, `props` (nullable), `source` (nullable, scripts only) | `Instance.new` + whitelisted props | class must be creatable; parent must resolve and not be under the store or `CoreGui` |
| `set_props` | `targets` (1–50), `props` | whitelisted property/attribute writes on each target | see return contract below |
| `move` | `targets` (1–50), `newParent` | reparent | same parent refusals as `create` |
| `trash` | `targets` (1–50) | §4.4 | destructive prompt per §8.4 |

- **Syntax gate:** before any script write lands (`replace_lines`, `edit_script`, `write_script`, `create` with `source`), the executor compiles the new source with `loadstring` in pcall and never invokes it; a compile error refuses the call with `{ok=false, error="syntax error: …"}`. This is the only check that catches a broken LocalScript, since Run mode has no client.
- **`props` wire shape** (strict-schema compatible, §6.1): an array of `{ name: string, value: string }` where `value` is a JSON-encoded scalar or table (`"true"`, `"Neon"`, `"{\"x\":1,\"y\":2,\"z\":3}"`); attribute names carry an `@` prefix (`@Speed`). The plugin JSON-decodes each value and type-checks it against §5.4.
- **`set_props` return contract:** `{ok=true, applied=[…], rejected={ name = "reason" }}` when at least one key applied; `{ok=false, error=…}` only when nothing applied. Rejected keys are not tool errors for the §6.3 counter.
- Script writes go through `UpdateSourceAsync(script, fn)` (S1 may route unopened scripts to `.Source`). The callback **may not yield** and never prompts or touches the store. `edit_script` and `replace_lines` compute on `oldContent`; `write_script`/`create` ignore it. Multi-target calls run under one recording and one destructive prompt and return a per-target result list.

### 5.3 Control tools

| Tool | Phase | Args | Effect |
|---|---|---|---|
| `submit_plan` | PLANNING | the plan object (§7.2) | ends PLANNING → AWAITING_APPROVAL |
| `finish_step` | ACTING, REPAIRING | `outcome` (≤ 400 chars) | ends the step |
| `write_memory` | RECORDING | `notes`, `plan_summary` | replaces the Notes block (§4.2) and supplies the record's `summary` (§10) |

Control tools never count against `*_MAX_CALLS`. In a batch, non-control calls execute first in order; the control call is processed last and **only if the batch committed** (a cancelled or refused batch drops it with `{ok=false, error="finish_step ignored: batch did not commit"}`).

### 5.4 Property whitelist (inspect and set_props)

Encoded as JSON-friendly tables: `Vector3 → {x,y,z}`, `Color3 → {r,g,b}` in 0–255, `UDim → {s,o}`, `UDim2 → {xs,xo,ys,yo}`, enums as their `Name` string. On **read**, any other datatype falls back to `tostring(value)` tagged with `typeof` (an `ObjectValue` as a path) and never fails the whole `inspect`; on **write**, those types are refused.

- **Instance:** `Name`, `ClassName` (read), `Parent` (read; write via `move`), `Archivable`
- **BasePart:** `Anchored`, `CanCollide`, `CanTouch`, `CanQuery`, `Transparency`, `Reflectance`, `Color`, `Material`, `Size`, `Position`, `Orientation`, `CastShadow`, `Massless`
- **Model:** `PrimaryPart` (as path)
- **Lights:** `Brightness`, `Color`, `Range`, `Enabled`, `Shadows`; **Lighting:** `Ambient`, `OutdoorAmbient`, `Brightness`, `ClockTime`, `FogEnd`, `FogStart`, `FogColor`
- **GuiObject:** `Visible`, `Position`, `Size`, `AnchorPoint`, `BackgroundColor3`, `BackgroundTransparency`, `ZIndex`, `LayoutOrder`; **text classes** add `Text`, `TextColor3`, `TextSize`, `Font`, `TextScaled`, `TextWrapped`, `RichText`; **ScreenGui:** `Enabled`, `ResetOnSpawn`, `DisplayOrder`
- **UI helpers:** `UIListLayout`/`UIGridLayout` (`FillDirection`, `HorizontalAlignment`, `VerticalAlignment`, `SortOrder`, `Padding`, `CellSize`, `CellPadding`), `UICorner` (`CornerRadius`), `UIPadding` (`PaddingTop/Bottom/Left/Right`), `UIStroke` (`Color`, `Thickness`, `Transparency`)
- **Interaction:** `ProximityPrompt` (`ActionText`, `ObjectText`, `HoldDuration`, `MaxActivationDistance`, `Enabled`), `ClickDetector` (`MaxActivationDistance`), `Sound` (`SoundId`, `Volume`, `Looped`, `Playing`, `PlaybackSpeed`)
- **ValueBase:** `Value` (type-checked against the class); **BaseScript:** `Enabled`
- **Attributes:** `@name` entries; string, number, boolean only

Anything else: `rejected[name] = "property not whitelisted — write a Script if it must change at runtime"`.

---

## 6. Agent loop

### 6.1 Protocol and schemas

OpenAI chat-completions tool protocol on all providers: request `tools=[{type="function", function={name, description, parameters}}]`; response `message.tool_calls[]` with `id`, `function.name`, `function.arguments` (JSON string); the plugin appends the assistant message, then one `{role="tool", tool_call_id, content}` per call, in order. Rules the schemas obey so every provider accepts them:

- Schemas use only `type`, `properties`, `required`, `enum`, `items`, `additionalProperties=false`. **No free-form maps** (hence the `props` pair array), **no `minItems`/`maxItems`/`maxLength`**: every length and count limit is plugin-enforced and a violation is returned to the model once as `{ok=false}`.
- Every property is listed in `required`; **optional arguments are nullable** (`"type": ["integer","null"]`) and the executor treats JSON null (which `JSONDecode` drops to nil) as absent.
- **Every schema has at least one property**, because `HttpService:JSONEncode({})` emits `[]` and `"properties": []` is not valid JSON Schema; arg-less tools carry a required `reason: string` the plugin ignores.
- `strict=true` is sent only where `PROV[p].strictTools` is true (Cerebras until S5 proves others; Groq does not document it, A16).
- `parallel_tool_calls=true` is sent where the provider accepts it; on Groq gpt-oss has **no** parallel tool use (A1), so batches there are single-call.
- The assistant message is re-sent with its `reasoning` field intact while the same provider serves the phase (gpt-oss's harmony format expects its analysis back); on a mid-phase provider switch the field is dropped. `tool_choice` is not used; phases end when the model calls their control tool.

### 6.2 Provider changes (section 5 of the file)

- `callProvider(entry, messages, opts?)` gains `opts = { tools, maxTokens, temperature, strict, parallel, minimal }` and returns `{ text?, toolCalls?, reasoning?, usage?, truncated, entry }`.
- `MODEL_CHAIN` entries gain `tools = true|false`. **Goal queue** = `buildQueue()` filtered to `tools == true`. Initial flags (S5 confirms): Groq `gpt-oss-120b` ✓, `gpt-oss-20b` ✓; Cerebras `gpt-oss-120b` ✓, `zai-glm-4.7` ✗ (absent from Cerebras' current docs, likely dead; Chat's classifier will retire it); OpenRouter `gpt-oss-120b:free` ✓, `gpt-oss-20b:free` ✓ **if** their endpoints list is non-empty (S5), `nemotron…:free` ✗, `llama-3.3-70b…:free` ✗. Chat mode keeps the full chain and never sends `tools`.
- **OpenRouter Goal requests are minimal**: `model, messages, tools, max_tokens, temperature` plus `provider = { require_parameters = true }` and no `reasoning_effort`/`parallel_tool_calls`, because `require_parameters` filters on *every* parameter in the body (A7).
- `GOAL_MAXTOK = { groq = 4096, cerebras = 8192, openrouter = 8192 }` (v1's `MAXTOK` stays for Chat; its OpenRouter 2048 was a chat-timeout hedge that would truncate any real `write_script`). `temperature = 0.2`. If a **tool-call** response has `finish_reason == "length"`, the truncated call is not executed and the model gets `{ok=false, error="tool call cut off by the output limit; use replace_lines or edit_script, or split the change"}`.
- `reasoning_effort="low"` stays for gpt-oss on Groq and Cerebras, with the existing strip-and-retry.

### 6.3 Budgets (hard stops enforced by the plugin, not the prompt)

| Constant | normal | deep (`goal_effort`) | Applies to |
|---|---|---|---|
| `PLAN_MAX_CALLS` | 12 | 24 | PLANNING |
| `REVISE_MAX_CALLS` | 6 | 12 | a Revise re-plan (§7.3) |
| `ACT_MAX_CALLS` | 8 | 16 | per ACTING step |
| `REPAIR_MAX_CALLS` | 6 | 12 | REPAIRING |
| `REPAIR_PASSES` | 1 | 2 | repair rounds per cycle |
| `MAX_STEPS` | 10 | 10 | steps per plan (`submit_plan` with more is rejected once, then the phase fails) |
| `MAX_MODEL_TURNS` | calls + 2 | calls + 2 | per phase |
| `MAX_CONSECUTIVE_TOOL_ERRORS` | 3 | 3 | per phase |
| `PHASE_TOKEN_CEILING` | 150K est. | 300K est. | per phase, summed over served requests |
| `RECORDING` | exactly one request, tools `[write_memory]`, `MAX_MODEL_TURNS = 3` | same | §10 |

- **Batch rule:** budgets are checked per batch **before** the recording opens. If `used + #batch > MAX`, nothing executes, every call gets `{ok=false, error="call budget exhausted"}`, and the phase ends.
- **Consecutive tool errors** count model turns in which every non-control call failed for a model-attributable reason (unknown tool, bad args, find not found, syntax error, stale hash, whitelist refusal with nothing applied). Rollback collateral, user Skips, undo-unavailable and truncation results carry `attributable=false` and do not count.
- **Nudge rule (all phases):** a tool-less or refusal turn gets one user nudge naming the phase's control tool (`submit_plan`, `finish_step`, `write_memory`); two consecutive tool-less turns fail the phase. `MAX_MODEL_TURNS` still applies.
- **PLANNING exhaustion** (calls or tokens) runs one final turn with `tools=[submit_plan]` and "Budget reached. Submit the best plan you can from what you have read; mark uncertain steps `risk: high`." Only if that turn also fails does PLANNING return to IDLE.
- An **ACTING** exhaustion marks the step `failed` (§8.2). Waited requests (§6.7) count toward nothing: the 429 was never served.

### 6.4 Request sizing, routing, and the free-tier ceilings

`estTokens` = `#JSONEncode(body) / 4` for the first request of a conversation; afterwards `last usage.prompt_tokens + last usage.completion_tokens + (new tool-result chars / 3)`, since escaped Luau tokenizes denser than 4 chars/token. Before each request:

1. If `estTokens > GROQ_REQ_MAX`, Groq entries are skipped for this request. `GROQ_REQ_MAX` starts at 3,500 and S6 sets it (if Groq's TPM check counts `max_tokens`, `8000 - GOAL_MAXTOK.groq`; if not, 7,000). Groq is the **small-turn** provider in Goal Mode; Cerebras carries the loop.
2. If `estTokens > BIG_REQ_MAX (28000)` (Cerebras 30K TPM, A4), the phase conversation is **compacted**: the oldest `tool` results are replaced with `[result elided; call the tool again if needed]`, oldest first, until under the cap. If still over, the phase fails with "context too large for the free tiers".
3. If a provider itself rejects a request as too large (§6.5), compact once by the same rule and re-send to the remaining queue before treating the send as failed.
4. When Groq is excluded and no other key exists, the status is specific: "Request is ~N tokens; Groq's 8K limit excludes it and no Cerebras or OpenRouter key is available. Add one in Settings or narrow the goal."

**Ceilings, stated plainly (A2, A4, A7):** limits are per **organization/account**, not per key, so extra keys from the same account share one bucket; separate accounts are separate buckets (the "Known-false-until-proven" line in §17 still applies). Groq: 8K TPM and 200K TPD per org, so roughly one Goal-size request per minute and a few dozen per day. Cerebras: 5 RPM and 1M TPD, the only leg that survives a full cycle, paced by §6.7. OpenRouter free: about 20 RPM and **50 requests per day** per account with no purchased credits, request-count caps rather than TPM, so it is a fallback leg, not a workhorse. A per-provider request counter (session and, for OpenRouter, day) shows in the status line so the ceiling is visible before it is hit.

### 6.5 Failure classification changes

- **413 first, by status code.** `code == 413`, or `code == 400 and matchAny(bodyText, PAT_TOOLARGE)`, is checked **before** the 429/`PAT_RATELIMIT` branch and marks `failedProviders[p]` then rotates. Reason: Groq's observed 413 body carries `code: rate_limit_exceeded` and a `docs/rate-limits` URL, so v1 classifies it as a rate limit, cools the key for 30 s, and re-sends the same oversized body to each remaining Groq key. `PAT_TOOLARGE` also gains `"body is too large"` for the docs' generic wording. This is a v1 bug fix and ships in the v2 PR.
- **Malformed tool calls.** `code == 400` with a body matching new `PAT_BADTOOLCALL = { "tool_use_failed", "failed_generation" }` is a model-side fault, not a key fault: one same-entry retry (temperature 0), classified normally if it fails again, then a corrective tool-less turn to the model ("your last tool call had invalid JSON arguments; re-issue it, prefer replace_lines or edit_script over a large write_script"). Each attempt counts as a model turn.

### 6.6 Prompt caching discipline

The **system message is byte-stable across every Goal phase** (role, rules, tool guidance, the trash rule, output discipline, Roblox conventions). Everything variable (Facts + Notes, plan summaries, Selection and active script, the phase instruction, the pre-injected `index(game, 1)`) goes in the **first user message**, because gpt-oss's template renders tool definitions after the system text and a changing system message would break the cached prefix. Same rationale as v1: providers cache on the prefix.

### 6.7 Cooldown waits and pacing (implemented in AGENT around `chatOnce`, so Chat keeps v1's manual Retry)

- When `chatOnce` returns the cooling/exhausted message, `KeyStore.count() > 0`, and at least one Goal-queue entry is neither `Bad` nor in this phase's `failedProviders`/`failedModels`: `soonest = min(Cooling[id]) - os.clock()` over those entries. If `soonest ≤ GOAL_WAIT_MAX (90 s)`, status "Waiting Ns for <Provider> key #k", `task.wait(soonest + 1)`, re-check `myGen == gen and not unloaded`, re-send the identical request. At most `GOAL_WAITS_PER_REQUEST = 2` waits per request, then the phase fails as §11 describes. Stop interrupts a wait through the gen check.
- **Cerebras pacing:** a per-key last-request clock spaces requests to the same Cerebras key at least 12 s apart (5 RPM, no `retry-after` published), which is cheaper than a 30 s cooldown after a 429.

---

## 7. PLANNING

### 7.1 Inputs

- Goal text from the box, or empty for **Plan next**.
- Focus chips (multi-select, ids `bugs, quality, perf, ideas, polish`; labels `Bugs and errors`, `Code quality`, `Performance`, `Gameplay ideas`, `Polish`). Defaults: `bugs, quality`. Ticked chips are appended to the phase instruction in **both** a typed-goal PLAN and Plan next; Plan next with zero chips treats all five as ticked. Persisted as `goal_focus`.
- Memory (Facts + Notes), the last three plan summaries with failure lines and revision notes (§4.3), the top-level index, the current **Selection** (first 20 as `path | class | #ref`, via v1's `buildSelectionSummary`) and the **active script** (full name + line count), and, when `bugs` is ticked, the newest `read_output` result pre-injected.
- Read tools only. Ends with `submit_plan`.

Phase instruction (variable block): "Investigate with the read tools until you can write a plan of at most 10 steps. Each step must name its targets by path or #ref; selected instances and the active script are the likely targets when the goal says 'this'. Prefer `replace_lines` or `edit_script` over rewrites. Mark risk honestly. Then call `submit_plan`." For Plan next: "Propose the most valuable improvements along these focus areas: …".

### 7.2 `submit_plan` object

```
{ title: string(≤80), summary: string(≤600), verify_hint: string(≤200),
  steps: [ { title: string(≤80), action: "edit"|"create"|"move"|"trash"|"props"|"mixed",
             targets: string[] (≥1), detail: string(≤500), risk: "low"|"medium"|"high" } ] (1..10) }
```
Limits are plugin-enforced (§6.1). `verify_hint` is shown on the plan card and seeds REPAIRING.

### 7.3 Plan card (AWAITING_APPROVAL)

Title, summary, `verify_hint`, one row per step: **include checkbox** (default on), title, action badge, risk dot, targets truncated to one line, `View` opens the detail in the modal. Buttons: **Approve** (clears the goal box, runs included steps in order), **Revise** (modal with a note box; appends `[revision note] …` to the **kept PLANNING transcript**, compacted per §6.4 if needed, and re-enters PLANNING under `REVISE_MAX_CALLS`, so the model does not re-read what it just read; the prior plan and the note are appended to `revisions[]`), **Cancel** (RECORDING with `status="cancelled"`). Unticking every step disables Approve.

---

## 8. ACTING

### 8.1 Per-step conversation

Each included step runs as its **own** conversation: the byte-stable system message, then a first user message with Memory, the approved plan JSON, "You are executing step n: …", a fresh `inspect` of each target, and, for script targets, the **numbered source pre-injected** with its hash up to `STEP_SEED_MAX = 24000` chars (head/tail like v1's `SCRIPT_HEAD`/`SCRIPT_TAIL` beyond that, with a note to page with `read_script`). Then the loop with read + write tools until `finish_step` or a budget stop. The PLANNING transcript is never resent. The plugin computes the real `changed[]` and `writes[]` from the writes it executed.

### 8.2 Step outcomes and what follows

`done` (finish_step after a committed batch), `failed` (budget, consecutive errors, provider exhaustion after the §6.7 waits, or a write batch that could not get a recording), `skipped` (unticked, or not run), `stopped` (Stop pressed). After a `failed` step the act log offers **Retry step n** (re-runs step n as a fresh §8.1 conversation with the previous outcome appended) and **Continue from step n+1** (marks n `skipped`); choosing neither, or Stop, sends the cycle to RECORDING with later steps `skipped` ("not run: step n failed"). **VERIFYING runs only when every included step is `done`**; otherwise the cycle goes straight to RECORDING.

### 8.3 Recording rules

- **Invariant (restated):** no recording spans a model turn (HTTP yield). A recording opens after a model turn returns write calls and after the §8.4 prompts are answered, wraps that batch, and commits before the next model turn. `UpdateSourceAsync` is the **one bounded yield allowed inside a recording** (A10); after every `UpdateSourceAsync` return the executor re-checks `myGen == gen and not unloaded` and on mismatch calls `FinishRecording(Cancel)` on its own recording and refuses the rest of the batch with `{ok=false, error="stopped"}`. **Only the coroutine that opened a recording finishes it**, so `FinishRecording` is never called twice on one id.
- Label: `RoScript Pro: Step n` (`, part k` when a step has more than one write batch). Each batch is one Ctrl+Z entry; on Groq gpt-oss every write arrives alone (A1), so a step there yields one entry per write.
- `TryBeginRecording` nil → the batch is not executed, every call gets `{ok=false, error="undo unavailable, writes refused", attributable=false}`, the step is `failed`. No recording ⇒ no write, as v1.
- A write that throws mid-batch → the batch's recording is **cancelled** (all writes in it revert), the throwing call gets its error, the others `{ok=false, error="batch rolled back", attributable=false}`, and any control call in the batch is dropped (§5.3).

### 8.4 Prompts before the recording opens (D2)

Before `TryBeginRecording`, the executor walks the batch in order, simulating each script's source in memory so later calls see earlier ones, and collects every prompt; all prompts are answered first, then the recording opens. Prompts fire for:
- `trash` of a target that has descendants or is a `LuaSourceContainer`;
- `write_script` on an existing script with > 200 lines where the line-set diff changes > 50% of lines, **unless** the approved step declared `risk: high` and the target is in its `targets`;
- any write whose target (or an ancestor of it) is **not** in the current step's `targets`, and any `create` whose parent is not: "approve once" approves the declared targets, not arbitrary writes.

The modal shows what will happen (new source and changed-line count for a rewrite, subtree summary for a trash, the argument table otherwise) with **Allow** / **Skip this call** / **Stop plan**. `Careful` on: every write call prompts. A Skip is `attributable=false` and the step can still finish.

### 8.5 Act log

One line per event: `Step 2/5 · replace_lines ServerScriptService.Shop:40-52 · done (undo: Step 2)`, tool errors muted, failures in the error colour, skips noted. `View` on a batch shows per write: `replace_lines` → the numbered range and new text; `edit_script` → find and replace; `write_script`/`create` → full new source and changed-line count; `set_props`/`move`/`trash` → the argument table. Status line: `phase · provider model · calls used/budget · requests this session`.

---

## 9. VERIFYING and REPAIRING (Run-button driven, D5)

### 9.1 Why the button

`RunService:Stop()` "will not restore the experience to the state it was in prior to the simulation being run" (A15), while the Studio Stop **button** "resets all objects and instances to how they were before the playtest" (A9). `ChangeHistoryService` is disabled at runtime, so a programmatic run would bake every startup side effect into the place with no undo. The plugin therefore never calls `Run()`/`Stop()`; Jasper does, with the button.

### 9.2 Sequence

Only if `goal_verify_enabled` and the cycle reached VERIFYING (§8.2). The result of ACT is shown with a **verify card**: "Press Run (F8), let it run a few seconds, then Stop." The plugin records the last pre-run `GetLogHistory()` entry's timestamp, connects `MessageOut`, then polls `IsRunning()` on `Heartbeat`: capture while true, finalise on the transition back to `IsEdit()`. The card shows a live error/warning count and elapsed time; nothing auto-stops. Skip on the card records `verify.ran=false`. Note on the card: a Run executes every server Script against live services (DataStore, HTTP) exactly as any playtest does.

### 9.3 Capture

Primary: `MessageOut` lines with `MessageError`/`MessageWarning` (cap 4,000 chars) plus the first 60 `MessageOutput` lines (`verify.output`). Fallback (S2): after Stop, scan `GetLogHistory()` from the end and take entries with `timestamp >= boundary - 1` (same-second tolerance; over-inclusion is harmless). The history is a **512-entry ring** (A11): if no pre-run entry survives, set `verify.overflowed=true`, report what was captured, and never print "0 errors" for an overflowed capture ("capture truncated, result inconclusive"; REPAIRING treats it as errors-unknown and does not run).

### 9.4 Repair

Errors are split: those whose message or traceback names a script in the plan's `changed[]` trigger **REPAIRING**; the rest go to `verify.preexisting` and the result card says "pre-existing, not touched". REPAIRING is one ACT-shaped conversation seeded with the triggering errors, `verify_hint`, the changed-script list, and "fix only what these errors point at; do not extend the plan"; budgets `REPAIR_MAX_CALLS`/`REPAIR_PASSES`; write batches labelled `RoScript Pro: Repair, part k`; ends on `finish_step`, budget, or three errors; its writes go to `verify.repair`. After a repair pass the verify card returns: "Press Run again to confirm." `errorsAfter` is what that run captured; `repair.outcome` is the model's, `errorsAfter` is the truth.

---

## 10. RECORDING and Plan next

1. Wait for `IsEdit()` (§4.1). Build the record from the plugin's own bookkeeping (§4.3): `status`, `steps[]` with `changed[]`/`writes[]`, `revisions[]`, `verify`, `models` = distinct `provider/model` pairs that answered, `estTokens` = summed estimates.
2. One request with `tools=[write_memory]`: "Here is the current Memory (Facts and Notes) and the record of what just happened. Rewrite Notes (≤ 3,500 chars, keep the headings) and give a ≤ 2,000-char summary of this plan." If the call never comes after the nudge, Notes stay as they were and `summary` falls back to the plan's own `summary`.
3. Inside **one** `RoScript Pro: record` recording: write Memory (Facts regenerated + Notes), the Manifest, the record chunks, `before/` chunks, folder attributes; apply the §4.5 caps.
4. Result card: `Plan_003 · partial · 4/5 steps done · Run: 0 errors, 2 warnings (1 pre-existing) · repaired: yes`, a hint line "Ctrl+Z removes this record first, then Step n", buttons **Plan next**, **Revert plan**, **View record**, **Open plans**.

**Plan next** always starts PLANNING with an empty goal and the improvement instruction, ignoring the box. The toolbar `Plan` button re-labels to `Plan next` when the box is empty and starts an ordinary PLAN when it is not. Starting a new cycle collapses the previous cards.

---

## 11. Error handling and reload safety

- **Generation counter:** every phase captures `myGen`; every post-yield step re-checks `myGen == gen and not unloaded` before touching the UI, the store, or the place. Stop and unload bump `gen`. **Cleanup is exempt** (disconnecting connections, cancelling the coroutine's own recording) and runs first.
- **Unloading:** as §3. The plugin never stops a playtest it did not start, and it starts none.
- **Provider exhaustion** inside a phase: if every remaining key is only cooling and the soonest deadline is within `GOAL_WAIT_MAX`, the phase waits (§6.7) and resumes; otherwise it fails with v1's messages and the plan is recorded with the failed step.
- **Store corruption** (a chunk that is not valid JSON): `read_plan` returns `{ok=false}`, the Plans list marks the record `unreadable`, PLANNING proceeds without it.
- **Studio state guards:** PLAN/ACT refuse to start while `IsRunning()` ("stop the playtest first"); Goal view buttons disable accordingly. If a model turn returns while `IsRunning()` is true (Jasper started a playtest between turns), the batch is refused with `attributable=false` and the step waits for `IsEdit()` before retrying that turn once.
- Refusals (`PAT_REFUSAL`) count as tool-less turns under the §6.3 nudge rule.

---

## 12. Settings (added to section 2 of the file)

| Key | Default | Set from | Meaning |
|---|---|---|---|
| `goal_mode` | `false` | top-bar toggle only | which view the dock shows |
| `goal_focus` | `{bugs=true, quality=true}` | focus chips only | stored as a map of `id → true` (avoids the array round-trip trap) |
| `goal_verify_enabled` | `true` (S3-dependent) | settings panel | show the verify card after ACT |
| `goal_careful` | `false` | settings panel | every write prompts |
| `goal_effort` | `"normal"` | settings panel | `normal` or `deep` (§6.3 column) |

The settings panel gains a "Goal Mode" group exposing the last three; the first two are live UI state.

---

## 13. UI

- **Top bar:** a `Chat|Goal` toggle to the left of `CTX:ON`. The toggle swaps two child frames of `root` (`chatView`, `goalView`); `CTX` applies to Chat only and dims in Goal.
- **Goal view, top to bottom:** goal `TextBox` (`MultiLine=true`, 3 lines, placeholder "Describe the goal… or leave empty and press Plan next"), focus chips row (five toggles, active = accent), a button row `Plan`/`Plan next` · `Plans (n, ~size)` · `Trash (n)`; below, a `ScrollingFrame` hosting, in order, the **plan card** (§7.3), the **act log** (§8.5), the **verify card** (§9.2), and the **result card** (§10). Cards are `Frame`s with `AutomaticSize.Y` in a `UIListLayout`.
- **Plans view** (replaces the scroll content until Back): rows `id · status · goal`, paged Older/Newer; a row opens the record with `summary` first and a `Raw` button for the JSON (split across labels like v1's `LABEL_MAX`); `Revert plan` per row.
- **Trash view:** rows with `Restore`; `Empty Trash` at the bottom with a confirm modal.
- **Modal host** reused for: step detail, §8.4 prompts, batch view, revise note, confirms. Modals stay `Active=true` (v1 fix).
- **Busy state:** `Plan`/`Approve` disabled and `Stop` shown while any phase runs; status line carries phase, budget, and request counters.
- Design rules as v1: no emojis in UI, hover state on every button, `Enum.Font.Code` for source, RichText escaped `&` then `<` `>`.

---

## 14. File layout, interfaces, build order, cut line

Banner sections after the change (BOOTSTRAP stays last):

```
1. CONFIG  2. SETTINGS  3. PROMPT & SKILLS  4. CONTEXT  5. PROVIDER  6. APPLY & RUN  7. UI
8. STORE   9. TOOLS     10. AGENT           11. GOAL UI  12. BOOTSTRAP
```

**Boundaries and the upward interface.** STORE knows instances and JSON, not models. TOOLS knows the DataModel and recordings, not HTTP. AGENT knows messages, budgets and phases, and calls TOOLS by name through a dispatch table. GOAL UI renders state and calls `Agent.plan(goal)`, `Agent.approve(includedSet)`, `Agent.revise(note)`, `Agent.retryStep(n)`, `Agent.continueFrom(n)`, `Agent.stop()`. Because TOOLS and AGENT (sections 9–10) must call *up* into GOAL UI (section 11), CONFIG forward-declares `GoalUI = { log, setPhase, prompt(kind, payload) → "allow"|"skip"|"stop", showCard, refreshPlans }` with no-op defaults that section 11 fills, exactly as v1 does with `UI`. PROVIDER changes (§6.2, §6.5) are the only edits inside v1 sections besides CONFIG constants, SETTINGS keys, and the top-bar toggle.

**Build order:** STORE (+S4) → TOOLS read set → AGENT PLANNING + plan card → TOOLS write set + ACTING + act log + Trash view (+S1, S5) → **RECORDING + Plans view + Revert** → VERIFYING/REPAIRING (+S2, S3) → settings group → classifier fix.

**Cut line: after RECORDING.** A plugin that plans, edits, records and can revert, with no verify card, is still the assistant that was asked for and still has "Plan next". VERIFY ships behind its setting when S2/S3 pass.

**Dev loop:** unchanged from v1 (Plugin Debugging Enabled, Save and Reload, drop-in copy to `%LOCALAPPDATA%\Roblox\Plugins`). Expected size ≈ 1,900 new lines on top of 1,966.

---

## 15. Manual test checklist (per sitting, no automation pretense)

1. Fresh place, no store: Plan with a goal → store folder appears with `RSP_StoreVersion=1`, plan card renders with `verify_hint`, all steps ticked.
2. Revise with a note → new plan differs and mentions the note; the status shows far fewer calls than the first plan; the record's `revisions[]` has one entry.
3. Approve a 3-step plan through RECORDING → Ctrl+Z once removes the record and Memory rewrite (Plans list drops the row), the next three revert the steps in reverse order, Ctrl+Y four times restores everything.
4. A step that edits the script open in the editor, with an unsaved edit in the buffer → the model's read shows the unsaved text; the edit lands on it; the tab updates without reopening.
5. A step that trashes a Model → prompt; Allow → Model in Trash with `RSP_OrigParent`; Restore puts it back; Restore into a folder that now holds a same-named sibling → rename/replace prompt.
6. Careful on → every write prompts; Skip one call → the step still finishes and the log shows the skip.
7. A step whose write targets a script the plan never declared → §8.4 prompt fires; Stop plan → record `status="stopped"`.
8. A `write_script` with a missing `end` → refused with the syntax error; the model's next call fixes it.
9. Verify on; a plan that introduces `error("boom")` on purpose → verify card; F8, wait, Stop → the error is captured and attributed to the changed script; repair pass edits it; second run shows `errorsAfter` empty; a pre-existing error in an untouched script lands in `preexisting`.
10. Stop during ACT → arrives between batches or during an `UpdateSourceAsync` yield; the last committed batch stays undoable, later steps `skipped`, record `status="stopped"`; no playtest was started or stopped by the plugin.
11. Groq keys only, goal on a large place → status shows the specific "Groq's 8K limit excludes it" message; with one Cerebras key added the request goes through; force a >7,000-token request with Groq keys → one 413 marks Groq failed for that request and no second Groq key is tried.
12. One Cerebras key only, a 3-step plan → status shows at least one "Waiting Ns" line; the plan completes with no failed step.
13. Plan next with Memory present → the proposal names systems from Facts; Notes rewritten ≤ 3,500 chars; a script edited by hand between cycles shows `edited-outside` in `index` and in Facts.
14. Revert plan on the record from item 3 → all three files restored; edit one file by hand first → that file is skipped and listed.
15. Save and Reload mid-phase → nothing stale reaches the UI or the place; store intact.
16. Open the place in a new Studio session → Plans list reads the records; a stale `#r` ref in a record resolves by path; `Retry step n` on a failed record's step is not offered (records are read-only across sessions).
17. Trash at 26 items or a record at 21 → the oldest is removed at RECORDING with a status line.

---

## 16. Deliberately NOT in v2

Streaming (`CreateWebStreamClient`, still a v3 candidate) · screenshots or Play-with-character (the plugin cannot; Studio MCP can) · programmatic `RunService:Run()`/`Stop()` (the method does not restore state) · `tool_choice` · multi-plan queues · a plan editor beyond include/exclude and Revise · cross-place or cross-machine memory · store migrations · parallel step execution · diff rendering beyond changed-line counts and find/replace display · Chat-mode access to the tools · exporting plan records · a `run_snippet` write tool over v1's `runOnce` · **split-source build** (`studio-plugin/src/NN-section.lua` concatenated into the one shipped file by a small script; the Contrarian's case for it is sound and it is the first v3 chore if the single file passes 4,000 lines).

---

## 17. Verified-facts appendix (checked 2026-09-03; rev 2 corrections marked ✎)

| # | Fact | Source | Quote / note |
|---|---|---|---|
| A1 ✎ | Groq tool use supports `openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `llama-3.3-70b-versatile` (and others). **Parallel tool use: No for both gpt-oss models**, Yes for llama-3.3-70b. `strict` on function definitions is not documented (→ A16) | console.groq.com/docs/tool-use | table shows "No ❌" for gpt-oss parallel tool use |
| A2 | Groq free tier, gpt-oss-120b and 20b: RPM 30 · RPD 1K · TPM 8K · TPD 200K; 429 on limit; headers `x-ratelimit-remaining-tokens`, `retry-after`; limits are per organization | console.groq.com/docs/rate-limits | "our API returns a 429 Too Many Requests HTTP status code" |
| A3 | Groq documents **413 Request Entity Too Large**; the observed body also carries `rate_limit_exceeded` (S6 confirms) | console.groq.com/docs/errors | "The request body is too large. Please reduce the size of the request body." |
| A4 | Cerebras Free Trial, gpt-oss-120b: RPM 5 · TPM 30K · TPH 1M · TPD 1M; limits per organization | inference-docs.cerebras.ai/support/rate-limits | page also mentions "$5 in free credits after adding a verified payment method"; not needed, not used ($0 rule) |
| A5 | Cerebras supports `tools`/`tool_calls`, `parallel_tool_calls`, and **strict mode** (`"strict": true` + `additionalProperties: false`, every property required, no unenumerated keys) | inference-docs.cerebras.ai/capabilities/tool-use | "Strict mode ensures that the model generates tool call arguments that exactly match your defined schema" |
| A6 | Cerebras tool-use docs name only gpt-oss-120b; `zai-glm-4.7` is absent from the current docs | same | → `tools=false`, likely dead |
| A7 ✎ | OpenRouter standardises tool calling; `provider.require_parameters` restricts to providers supporting **all** request parameters; `tools` alone is otherwise a soft preference; free models are capped by **requests per day** (about 50 without purchased credits) and ~20 RPM per account | openrouter.ai/docs/guides/features/tool-calling · /docs/guides/routing/provider-selection · /docs/api-reference/limits | "only use providers that support all parameters in your request" |
| A8 ✎ | `RunService.Run`, `Pause`, `Stop`, `IsEdit` are PluginSecurity; descriptions exist in the creator-docs yaml source though the rendered page hides them | github.com/Roblox/creator-docs …/classes/RunService.yaml | see A15 |
| A9 ✎ | The Studio **Stop button** "resets all objects and instances to how they were before the playtest". Run mode "does not insert your avatar". This describes the button, not the method | create.roblox.com/docs/studio/testing-modes | verbatim |
| A10 ✎ | `ScriptEditorService:UpdateSourceAsync(script, callback)` is a **yielding** call; it writes `Source` when the editor is closed; the callback may be re-invoked with fresher content and must compute on the content it receives | create.roblox.com/docs/reference/engine/classes/ScriptEditorService | → S1 for undo behaviour |
| A11 ✎ | `LogService:GetLogHistory()` "is capped at a maximum of 512 entries by default"; entries carry `message`, `messageType`, `timestamp` (seconds), `context`. `MessageOut(message, messageType, context)` fires for every engine output line | github.com/Roblox/creator-docs …/classes/LogService.yaml | replaces the former A11 (`GetDebugId`), which is no longer used: `GetDebugId(4)` returns `<scope>_<index>` (doc sample `39FA_12`), the scope shared by every instance, so the first characters do not identify an instance |
| A12 | `MessageOut` delivery to the plugin during a Run-button playtest is not documented | same | → S2 |
| A13 ✎ | `StringValue.Value` "can't be more than 200,000 characters; anything longer causes a `String too long` error" | github.com/Roblox/creator-docs …/classes/StringValue.yaml | `CHUNK_MAX = 100000` fits with margin |
| A14 | v1 classifier checks 429/`PAT_RATELIMIT` before the 400/`PAT_TOOLARGE` branch (`classifyFailure`, PROVIDER section) | `studio-plugin/RoScriptPro.lua` @ `17db5c6` | → §6.5 order rule |
| A15 ✎ | `RunService:Stop()`: "In contrast to the **Stop** button in Studio, calling this method will not restore the experience to the state it was in prior to the simulation being run." `IsRunMode()`: "this method will return `false` if the simulation was started using `RunService:Run()`." `IsRunning()` "will always return the inverse of `IsEdit()` except when paused." | github.com/Roblox/creator-docs …/classes/RunService.yaml | the reason D5 is button-driven |
| A16 ✎ | `strict` on tool definitions is documented by Cerebras only; Groq documents `strict` for `response_format` alone | console.groq.com/docs/tool-use · inference-docs.cerebras.ai/capabilities/tool-use | → per-provider `strictTools` flag, S5 |
| A17 ✎ | `ChangeHistoryService` "is not enabled at runtime, so calling its methods in a running experience has no effect" | github.com/Roblox/creator-docs …/classes/ChangeHistoryService.yaml | why a programmatic run has no undo |

**Unverified by design, spike-gated:** S1–S6 above. **Known-false-until-proven:** that free-tier keys from different accounts are independent rate-limit buckets on Groq and Cerebras (limits are documented per organization; separate accounts are separate organizations, same-account keys are not); if wrong, the routing rules still hold and only the throughput multiplier shrinks. **Observed, not documented:** Groq's 413 body wording and whether its TPM check counts `max_tokens` (S6).
