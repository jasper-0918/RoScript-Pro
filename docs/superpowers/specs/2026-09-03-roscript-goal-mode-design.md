# RoScript Pro Studio Plugin v2 — Goal Mode design

**Date:** 2026-09-03 · **Status:** design approved in brainstorm, spec pending Jasper's review · **Base:** v1 plugin on `main` (`17db5c6`), spec `2026-09-02-roscript-studio-plugin-design.md`

Goal Mode turns the v1 chat shell into an in-Studio assistant that can see the whole workspace, plan a change, carry it out across files, verify by running the game, and remember what it did so the next plan starts from a summary instead of a transcript. It is a bounded plan → act → verify cycle with Jasper between cycles, not an unattended loop. The unattended loop stays with Claude Code + Roblox's Studio MCP server, which has screenshots and Play-with-character that a plugin cannot get.

---

## 1. Settled decisions (from the 2026-09-03 brainstorm; do not reopen without cause)

| # | Decision | Chosen |
|---|---|---|
| D1 | Agent architecture | **Native OpenAI-style tool calling** inside the plugin. All three providers speak it (appendix A1, A5, A7). Text-protocol and one-shot apply-script approaches rejected. |
| D2 | Act gating | **Approve the plan once.** Prompt only before destructive steps (§8.4). A `Careful` setting makes every write prompt. |
| D3 | Context store | **`ServerStorage.RoScriptPro`**, saved with the place. Per-place by construction; ServerStorage never replicates to clients. |
| D4 | Deletes | **Never `Destroy`.** `trash(target)` moves into `ServerStorage.RoScriptPro.Trash` with the original path recorded. |
| D5 | Verification | **Auto Run mode** for a few seconds, capture Output, one budgeted repair pass. Toggle in settings. |
| D6 | File shape | **Still one file** (`studio-plugin/RoScriptPro.lua`); drop-in install is the point. Goal Mode lands as four new banner sections with hard boundaries (§14). |
| D7 | Scope | The cycle is one goal at a time. "Plan next" starts a new cycle from memory. No multi-plan queue. |
| D8 | Spend | $0 rule unchanged. Free tiers, keys in plugin settings, never in the repo. |

---

## 2. Spike checklist — run in Studio before coding (gates the build)

Throwaway plugin `RSP_Spikes2.lua` in `Downloads\Personal\`, pasted into `%LOCALAPPDATA%\Roblox\Plugins`, prints `[RSP SPIKES2] Sn PASS|FAIL detail`. **Delete it after** (it carries a pasted key for S5/S6). One Studio sitting.

| Spike | Question | Pass criterion | On FAIL |
|---|---|---|---|
| **S1** | Does `ScriptEditorService:UpdateSourceAsync` work on a script that is **not open** in the editor, and does a write wrapped in `TryBeginRecording` land in undo? | Source changes on an unopened Script; Ctrl+Z reverts it. | `write_script`/`edit_script` use `.Source` for unopened scripts (v1 path) and `UpdateSourceAsync` only when `StudioService.ActiveScript == target` or the doc is open. |
| **S2** | Does `LogService.MessageOut` fire in the **plugin** context while `RunService:Run()` is active, for a Script that prints and then errors? | Plugin receives both the print and the error with `MessageType.MessageError`. | Read `LogService:GetLogHistory()` right after `Stop()` and diff against a pre-run snapshot. |
| **S3** | Can the plugin call `RunService:Run()` then `RunService:Stop()`, and does `ChangeHistoryService:TryBeginRecording` return non-nil again afterwards? | `IsRunMode()` flips true then false; a post-Stop recording succeeds and commits. | Ship with `goal_verify_enabled=false` default and the §14 cut line; VERIFY stays in the file behind the setting. |
| **S4** | What is the real `StringValue.Value` length cap? (Docs state none; community reports ~200K.) | 150,000 chars write and read back equal. Record whether 250,000 also survives. | `CHUNK_MAX` drops to 50,000. |
| **S5** | Exact `tool_calls` shape from gpt-oss on **each** provider, and does a `tool`-role message round-trip? | One request with the `index` tool declared returns `choices[1].message.tool_calls[1].function.{name,arguments}` with `arguments` a JSON string; the follow-up with a `tool` message and `tool_call_id` returns 200. Run on Groq, Cerebras, OpenRouter (`require_parameters=true`). | That provider's chain entries get `tools=false` and drop out of the Goal queue. |
| **S6** | What does Groq return for a single request larger than the 8K TPM cap? | Record status code and body text. Expected 413 with "request body is too large" (appendix A3). | None needed: §6.5 classifies both the 400 and 413 forms. Update `PAT_TOOLARGE` if the body text differs. |

**Build order gate:** S1 and S5 gate ACT. S2 and S3 gate VERIFY. S4 gates the store chunk size. S6 gates nothing (defensive).

---

## 3. The cycle

```
IDLE ──Plan──▶ PLANNING ──submit_plan──▶ AWAITING_APPROVAL ──Approve──▶ ACTING(step 1..n)
  ▲                                            │ Revise ─▶ PLANNING (with note)        │
  │                                            │ Cancel ─▶ IDLE                        ▼
  │                                                                              VERIFYING (if enabled)
  │                                                                                    │ errors ─▶ REPAIRING (one pass)
  └──────────────────────── RECORDING ◀────────────────────────────────────────────────┘
```

- **Stop** (button) from any non-idle state: bump `gen`, cancel any open recording, if `IsRunMode()` then `RunService:Stop()`, write a plan record with `status="stopped"`, return to IDLE.
- **Plugin unload** mid-cycle behaves like Stop without the record write (no yields allowed in `Unloading`).
- Each state has its own tool set (§5), message seeding (§7, §8), and budgets (§6.3).
- "Plan next" is PLANNING with an empty goal; the model proposes improvements along the ticked focus chips (§7.1).

---

## 4. Context store

### 4.1 Layout

```
ServerStorage
└─ RoScriptPro                     Folder   attrs: RSP_StoreVersion=1
   ├─ Memory                       Folder   → chunk_1..n (StringValue)   plain text, ≤ MEMORY_MAX
   ├─ Plans                        Folder
   │   └─ Plan_001_add-shop-ui     Folder   attrs: RSP_Status, RSP_CreatedAt, RSP_Goal(≤200)
   │       └─ chunk_1..n           StringValue   JSON plan record (§4.3)
   └─ Trash                        Folder
       └─ <moved instances>        attrs: RSP_OrigPath, RSP_OrigRef, RSP_Plan, RSP_TrashedAt
```

- Created lazily on the first PLAN. If `ServerStorage.RoScriptPro` exists with a **different** `RSP_StoreVersion`, Goal Mode refuses to start and says so; no silent migration in v2.
- **Chunking:** text is split at `CHUNK_MAX = 100000` chars (S4 may lower it) into `chunk_1..n`; readers concatenate in numeric order. Writers create/overwrite chunks then delete any surplus `chunk_k`, k>n.
- All store writes go through `Store.write*` helpers which wrap their instance edits in **their own** ChangeHistory recording named `RoScript Pro: store`. A store write never shares a recording with a game edit, so undoing a step never undoes the record of it.
- The store is **protected**: the write tools of §5.2 refuse any target under `ServerStorage.RoScriptPro` except `trash()` moving *into* Trash. Read tools may index it (the model is told what it is).

### 4.2 Memory

Plain text, `MEMORY_MAX = 6000` chars. Model-maintained via `write_memory(text)` at RECORDING; the plugin **replaces**, never appends. The system prompt tells the model to keep these headings: `Game`, `Systems and where they live`, `Conventions`, `Decisions`, `Known issues`. If the model returns >6000 chars the plugin trims at a paragraph boundary and notes `[trimmed]`.

### 4.3 Plan record (JSON, one per cycle)

```json
{
  "v": 1,
  "id": "Plan_003_fix-shop-errors",
  "createdAt": 1756900000,
  "goal": "…",                       "focus": ["bugs","quality"],
  "plan": { "title": "…", "summary": "…", "verify_hint": "…",
            "steps": [ { "n":1, "title":"…", "action":"edit", "targets":["ServerScriptService.Shop"],
                         "detail":"…", "risk":"low", "included":true } ] },
  "steps": [ { "n":1, "status":"done|failed|skipped|stopped", "outcome":"…",
               "changed":[ { "path":"…", "ref":"#a1b2", "hashBefore":"9f3e…", "hashAfter":"01cc…" } ],
               "undoLabels":["RoScript Pro: Step 1"] } ],
  "verify": { "enabled":true, "ran":true, "seconds":5, "errors":["…"], "warnings":2, "repaired":true },
  "models": ["cerebras/gpt-oss-120b"], "estTokens": 41000,
  "summary": "≤ 2000 chars, model-written at RECORDING"
}
```

- `id` = `Plan_` + zero-padded sequence + `_` + slug of the plan title (≤ 30 chars, `[a-z0-9-]`).
- **Hashes** are FNV-1a 32-bit over the script source, hex. Luau has no built-in hash; implemented with `bit32` in the STORE section. They let PLAN see which scripts changed since the last plan that touched them (`index` emits `changed-since-plan` when a stored hash mismatches).
- `PLANS_FED_TO_PLAN = 3`: PLANNING is seeded with the `summary` of the three most recent records plus the `status`/`outcome` lines of any `failed` or `stopped` steps in them.

### 4.4 Trash

`trash(target)` sets the four `RSP_*` attributes then reparents into `Trash`, inside the step's recording (so Ctrl+Z restores it too). The Goal view has **Empty Trash** (one confirm modal, then `Destroy` each child under a `RoScript Pro: empty trash` recording) and **Restore** per item (reparent to `RSP_OrigPath` if it resolves, else to Workspace, and clear the attributes).

---

## 5. Tools

Every tool is a Luau function `(args) -> resultTable`. Results are JSON-encoded as the `tool` message content. Failures return `{ ok = false, error = "…" }` to the model; they never throw into the loop. Three consecutive tool errors in a phase fail the phase (§6.3).

**Target resolution.** `target` accepts a full path (`ServerScriptService.Shop`, `Workspace.Map.Door`) or a **ref** (`#a1b2`). Refs are the first 4 chars of `inst:GetDebugId(4)` (PluginSecurity, appendix A11), emitted by `index`/`inspect`/`search`, and kept in a session-scoped `Refs` map (`ref → instance`, cleared on unload). Paths resolve via v1's `walkPath`; when siblings share a name the first match wins, which is why refs exist. Plan records store both; on a later session a stale ref falls back to its path.

### 5.1 Read tools (every phase)

| Tool | Args | Returns | Caps |
|---|---|---|---|
| `index` | `path` (default `game`), `depth` (1–3, default 2) | lines `name | class | children | lines(if script) | changed-since-plan? | #ref` | `INDEX_MAX_ENTRIES = 200` per call, then `…N more, narrow the path` |
| `inspect` | `target` | whitelisted properties (§5.4), attributes, tags, children summary | one instance |
| `read_script` | `target`, `fromLine`, `toLine` (optional) | source slice with line numbers, `totalLines`, `hash` | `READ_SCRIPT_MAX = 8000` chars per call; the model pages |
| `search` | `pattern` (Luau pattern), `root` (default `game`) | `path:line: text` hits | `SEARCH_MAX_HITS = 40`, line trimmed to 160 chars |
| `read_memory` | – | Memory text | – |
| `list_plans` | – | `id · status · createdAt · goal(≤120)` for the last 10 | – |
| `read_plan` | `id` | the plan record JSON | – |

`index` skips `CoreGui`, `Chat`, `TextChatService` internals, and camera/terrain children; it labels `ServerStorage.RoScriptPro` as `[RoScript Pro store]`.

### 5.2 Write tools (ACTING and REPAIRING only)

| Tool | Args | Effect | Guard |
|---|---|---|---|
| `write_script` | `target`, `source` | replace whole source | destructive prompt if existing script > 200 lines and > 50% of lines change (§8.4) |
| `edit_script` | `target`, `find`, `replace`, `all` (bool) | plain-text find/replace (not a pattern) | fails if `find` not found, or found more than once when `all=false` |
| `create` | `class`, `parent`, `name`, `props` (optional), `source` (scripts only) | `Instance.new` + whitelisted props | class must be creatable; parent must resolve; refuses parents under the store or `CoreGui` |
| `set_props` | `target`, `props` | whitelisted property/attribute writes | unknown or non-whitelisted keys are reported back, others still applied |
| `move` | `target`, `newParent` | reparent | same parent refusals as `create` |
| `trash` | `target` | §4.4 | destructive prompt if the target has descendants or is a `LuaSourceContainer` |

Script writes use `UpdateSourceAsync(script, fn)` (S1); the callback ignores its argument and returns the new source. Every write inside one model turn's batch runs under **one** recording (§8.3).

### 5.3 Control tools

| Tool | Phase | Args | Effect |
|---|---|---|---|
| `submit_plan` | PLANNING | the plan object (§7.2 schema) | ends PLANNING → AWAITING_APPROVAL |
| `finish_step` | ACTING, REPAIRING | `outcome` (≤ 400 chars), `changed` (optional list) | ends the step |
| `run_and_capture` | VERIFYING only (plugin-initiated, §9) | – | not callable by the model in v2; listed so the schema set is complete for v2.1 |
| `write_memory` | RECORDING | `text`, `plan_summary` | replaces Memory (§4.2) and supplies the record's summary (§10) |

### 5.4 Property whitelist (inspect and set_props)

Encoded as JSON-friendly tables: `Vector3 → {x,y,z}`, `Color3 → {r,g,b}` in 0–255, `UDim2 → {xs,xo,ys,yo}`, enums as their `Name` string.

- **Instance:** `Name`, `ClassName` (read), `Parent` (read; write via `move`), `Archivable`
- **BasePart:** `Anchored`, `CanCollide`, `CanTouch`, `CanQuery`, `Transparency`, `Reflectance`, `Color`, `Material`, `Size`, `Position`, `Orientation`, `CastShadow`, `Massless`
- **Model:** `PrimaryPart` (as path)
- **GuiObject:** `Visible`, `Position`, `Size`, `AnchorPoint`, `BackgroundColor3`, `BackgroundTransparency`, `ZIndex`, `LayoutOrder`; **text classes** add `Text`, `TextColor3`, `TextSize`, `Font`, `TextScaled`, `TextWrapped`, `RichText`
- **ValueBase:** `Value` (type-checked against the class)
- **BaseScript:** `Enabled`
- **Attributes:** `props.attributes = { name = string|number|boolean }`; other value types refused

Anything else: `{ok=false, error="property not whitelisted: X — write a Script if it must change at runtime"}`.

---

## 6. Agent loop

### 6.1 Protocol

OpenAI chat-completions tool protocol on all providers: request `tools=[{type="function", function={name, description, parameters, strict=true}}]`, `parallel_tool_calls=true`; response `message.tool_calls[]` with `id`, `function.name`, `function.arguments` (JSON string); the plugin appends the assistant message verbatim, then one `{role="tool", tool_call_id, content}` per call, in order. Parameter schemas set `additionalProperties=false` and list every property in `required` so Cerebras strict mode accepts them (appendix A5); the same schema is sent to every provider. `tool_choice` is **not** used (unverified on two providers); phases end when the model calls their control tool. Extra fields such as `reasoning` on the assistant message are dropped before re-sending.

### 6.2 Provider changes (section 5 of the file)

- `callProvider(entry, messages, tools?)` gains an optional `tools` argument and returns `{ text?, toolCalls?, truncated, entry }`. A response with neither content nor tool calls is "empty content" as today.
- `MODEL_CHAIN` entries gain `tools = true|false`. **Goal queue** = `buildQueue()` filtered to `tools == true`. Initial flags (S5 confirms): Groq `gpt-oss-120b` ✓, `gpt-oss-20b` ✓; Cerebras `gpt-oss-120b` ✓, `zai-glm-4.7` ✗ (not in Cerebras' tool-use docs); OpenRouter `gpt-oss-120b:free` ✓, `gpt-oss-20b:free` ✓, `nemotron…:free` ✗, `llama-3.3-70b…:free` ✗. Chat mode keeps the full chain.
- OpenRouter Goal requests add `provider = { require_parameters = true }` (appendix A7) so tools never route to a provider that drops them.
- Agent phases use `temperature = 0.2` (chat keeps 0.5). `max_tokens` stays `MAXTOK[provider]`; if a **tool-call** response has `finish_reason == "length"`, the plugin does not execute the truncated call and returns `{ok=false, error="your tool call was cut off by the output limit; use edit_script or split the change"}` for it.
- **`reasoning_effort="low"`** stays for gpt-oss, with the existing strip-and-retry.

### 6.3 Budgets (hard stops enforced by the plugin, not the prompt)

| Constant | Value | Applies to |
|---|---|---|
| `PLAN_MAX_CALLS` | 12 tool calls | PLANNING |
| `ACT_MAX_CALLS` | 8 tool calls | per ACTING step |
| `REPAIR_MAX_CALLS` | 6 tool calls | REPAIRING |
| `RECORD_MAX_CALLS` | 1 (`write_memory`) | RECORDING |
| `MAX_STEPS` | 10 | steps per plan (`submit_plan` with more is rejected back to the model once, then the phase fails) |
| `MAX_MODEL_TURNS` | calls + 2 | per phase; catches a model that talks without calling tools |
| `MAX_CONSECUTIVE_TOOL_ERRORS` | 3 | per phase |
| `PHASE_TOKEN_CEILING` | 150,000 estimated tokens | per phase, summed over requests |

Exhaustion ends the phase with a status message naming the budget. A PLANNING budget exhaustion returns to IDLE; an ACTING exhaustion marks the step `failed` and stops the plan (§11).

### 6.4 Request sizing and routing

`estTokens = #JSONEncode(body) / 4`. Before each request:

1. If `estTokens > GROQ_REQ_MAX (7000)`, Groq entries are skipped for this request (the queue is walked without them). Rationale: Groq free is 8K TPM **per key**, so a big request would be rejected on every key; skipping saves the keys for small turns (appendix A2).
2. If `estTokens > BIG_REQ_MAX (28000)` (Cerebras 30K TPM, appendix A4; OpenRouter free TPM is unpublished and treated the same), the phase conversation is **compacted**: the oldest `tool` results are replaced with `[result elided; call the tool again if needed]`, oldest first, until under the cap. If still over, the phase fails with "context too large for the free tiers".
3. Multi-key note: per-minute and per-day caps multiply with more keys on a provider, but the **single-request** size cap does not, which is why routing is by size and not by key count.

### 6.5 Failure classification changes

`classifyFailure` treats `code == 413` exactly like `code == 400 and matchAny(bodyText, PAT_TOOLARGE)`: mark `failedProviders[p]` and rotate. Today a Groq 413 (appendix A3) falls through to the generic rotate and every Groq key and model is tried with the same oversized body. `PAT_TOOLARGE` gains `"body is too large"`. This is a v1 bug fix and ships in the v2 PR.

### 6.6 Prompt caching discipline

The system prompt is a **byte-stable prefix** (role, rules, tool usage guidance, the trash rule, output discipline, Roblox conventions) followed by a variable suffix (Memory, plan summaries, phase instruction, a pre-injected `index(game, 1)` so the model saves a call). Same rationale as v1: providers cache on the prefix.

---

## 7. PLANNING

### 7.1 Inputs

- Goal text from the box, or empty for **Plan next**.
- Focus chips (multi-select): `Bugs and errors`, `Code quality`, `Performance`, `Gameplay ideas`, `Polish`. Defaults: first two. Persisted as `goal_focus`.
- Memory, the last three plan summaries with failure lines (§4.3), the top-level index.
- Read tools only. Ends with `submit_plan`.

Phase instruction (variable suffix): "Investigate with the read tools until you can write a plan of at most 10 steps. Each step must name its targets by path or #ref. Prefer `edit_script` over rewrites. Mark risk honestly. Then call `submit_plan`." For Plan next: "Propose the most valuable improvements along these focus areas: …". If the model replies in text without a tool call, the plugin appends one user nudge "Call submit_plan with your plan." and on a second text reply fails the phase.

### 7.2 `submit_plan` schema

```
{ title: string(≤80), summary: string(≤600), verify_hint: string(≤200),
  steps: [ { title: string(≤80), action: "edit"|"create"|"move"|"trash"|"props"|"mixed",
             targets: string[] (≥1), detail: string(≤500), risk: "low"|"medium"|"high" } ] (1..10) }
```

### 7.3 Plan card (AWAITING_APPROVAL)

Title, summary, one row per step: **include checkbox** (default on), step title, action badge, risk dot (green/amber/red), targets truncated to one line, `View` opens the detail in the modal. Buttons: **Approve** (runs included steps in order), **Revise** (modal with a note box; re-enters PLANNING with the previous plan JSON and the note appended to the goal), **Cancel** (record with `status="cancelled"`, back to IDLE). Unticking every step disables Approve.

---

## 8. ACTING

### 8.1 Per-step conversation

Each included step runs as its **own** conversation: system prefix + suffix (Memory, the approved plan JSON, "You are executing step n: …", the step's targets pre-resolved with a fresh `inspect` of each), then the loop with read + write tools until `finish_step` or a budget stop. The PLANNING transcript is never resent. `changed` in `finish_step` is advisory; the plugin computes the real list from the writes it executed.

### 8.2 Step outcomes

`done` (finish_step called), `failed` (budget, three tool errors, provider exhaustion, or a write batch that could not get a recording), `skipped` (unticked), `stopped` (Stop pressed). A `failed` step **stops the plan**; later steps are recorded as `skipped` with outcome "not run: step n failed". The act log says so and offers Plan next, whose seeding includes the failure (§4.3).

### 8.3 Recording rules

- A recording opens **after** a model turn returns write calls and **before** the first write of that batch; it commits after the batch's last write; the next model turn (an HTTP yield) starts only after the commit. **No recording ever spans a yield** (v1 invariant kept).
- Label: `RoScript Pro: Step n` (`, part k` appended when a step has more than one write batch). Each batch is one Ctrl+Z entry.
- If `TryBeginRecording` returns nil, the batch is not executed, the model gets `{ok=false, error="undo unavailable, writes refused"}` for every call in it, and the step is marked `failed`. Same invariant as v1: no recording ⇒ no write.
- A write that throws mid-batch: the batch's recording is **cancelled** (all writes in it revert), the model gets the error for that call and `{ok=false, error="batch rolled back"}` for the others.

### 8.4 Destructive prompts (D2)

The executor pauses the batch and opens a confirm modal before:
- `trash` of a target that has descendants or is a `LuaSourceContainer`;
- `write_script` on an existing script with > 200 lines where the line-set diff changes > 50% of lines.

Modal shows what will happen (for a rewrite, the new source and the changed-line count; for a trash, the subtree summary) with **Allow** / **Skip this call** / **Stop plan**. `Careful` setting on: **every** write call prompts. Prompts are answered before the recording opens, so a long think on Jasper's side never holds a recording open.

### 8.5 Act log

One line per event: `Step 2/5 · edit ServerScriptService.Shop · done (undo: Step 2)`, tool errors in the muted colour, failures in the error colour. `View` on a write batch opens the modal with, per write: `edit_script` → the exact find and replace; `write_script`/`create` → the full new source and changed-line count; `set_props`/`move`/`trash` → the argument table. Status line shows `phase · provider model · calls used/budget`.

---

## 9. VERIFYING and REPAIRING

- Runs only if `goal_verify_enabled` (default on if S3 passes) and at least one step is `done`.
- Sequence: snapshot `#LogService:GetLogHistory()` → connect `MessageOut` → `RunService:Run()` → wait `goal_verify_seconds` (default 5, range 2–20) → `RunService:Stop()` → disconnect. The docs confirm Run inserts no avatar and that Stop resets every instance to its pre-test state (appendix A9), so nothing the simulation does persists. Character-dependent scripts will not exercise; the model is told this.
- Capture: all `MessageError` and `MessageWarning` lines (cap 4000 chars), plus the first 60 `MessageOutput` lines. Fallback per S2: diff `GetLogHistory()` after Stop.
- **Writes are refused while `RunService:IsRunMode()`** by the executor, independent of the model.
- Errors present → **REPAIRING**: one ACT-shaped conversation seeded with the errors, the list of scripts the plan changed, and "fix only what these errors point at; do not extend the plan", `REPAIR_MAX_CALLS`, then **one** more Run of the same length whose result is recorded. No second repair.
- Any failure to enter or leave Run mode aborts VERIFY with a status line and proceeds to RECORDING with `verify.ran=false`.

---

## 10. RECORDING and Plan next

1. Build the plan record from the plugin's own bookkeeping (§4.3), with `models` = the distinct `provider/model` pairs that answered and `estTokens` = the summed estimates.
2. One model turn with only `write_memory` available: "Here is the current Memory and the record of what just happened. Rewrite Memory (≤ 6000 chars, keep the headings) and give a ≤ 2000-char summary of this plan. Then you are done." The call is `write_memory(text, plan_summary)`. If the call never comes, Memory stays as it was and `summary` falls back to the plan's own `summary` field.
3. Write the record under `Plans`, set the folder attributes, refresh the plans list.
4. Show the result card: `Plan_003 · 4/5 steps done · Run 5s: 0 errors, 2 warnings · repaired: yes`, buttons **Plan next**, **View record**, **Open plans**.

**Plan next** = PLANNING with the goal box left empty; the phase instruction switches to the improvement prompt (§7.1). If Jasper types a goal instead, it is an ordinary PLAN that still benefits from the fresh Memory.

---

## 11. Error handling and reload safety

- **Generation counter** carries over: every phase captures `myGen`; every post-yield step re-checks `myGen == gen and not unloaded` before touching the UI, the store, or the place. Stop and unload bump `gen`.
- **Unloading:** cancel any open recording, `RunService:Stop()` if in run mode, disconnect `MessageOut`, clear `Refs`. No store write (no yields in `Unloading`).
- **Provider exhaustion** inside a phase: the phase fails with the same messages v1 shows ("All keys are cooling down…"). The plan is recorded with the failed step.
- **Store corruption** (a chunk that is not valid JSON): `read_plan` returns `{ok=false}`, the plans list marks the record `unreadable`, PLANNING proceeds without it.
- **Studio state guards:** PLAN/ACT refuse to start while `IsRunMode()` or `IsRunning()` ("stop the playtest first"); the Goal view's buttons disable accordingly.
- Refusals (`PAT_REFUSAL`) during a tool phase count as a tool-less text turn (§7.1 nudge rule).

---

## 12. Settings (added to section 2 of the file)

| Key | Default | Meaning |
|---|---|---|
| `goal_mode` | `false` | which view the dock shows (`Chat`/`Goal`) |
| `goal_focus` | `{bugs=true, quality=true}` | focus chips (stored as a map of `id → true`, avoiding the array round-trip trap) |
| `goal_verify_enabled` | `true` (S3-dependent) | run VERIFY after ACT |
| `goal_verify_seconds` | `5` | Run duration, clamped 2–20 |
| `goal_careful` | `false` | every write prompts |

Keys and chain settings are unchanged. The settings panel gains a "Goal Mode" group with these five.

---

## 13. UI

- **Top bar:** a `Chat|Goal` toggle to the left of `CTX:ON`. The toggle swaps two child frames of `root` (`chatView`, `goalView`); `CTX` applies to Chat only and dims in Goal.
- **Goal view, top to bottom:** goal `TextBox` (`MultiLine=true`, 3 lines, placeholder "Describe the goal… or leave empty and press Plan next"), focus chips row (five toggle buttons, active = accent colour), a button row `Plan` (label becomes `Plan next` when the box is empty) · `Plans` · `Trash (n)`; below, a `ScrollingFrame` that hosts, in order, the **plan card** (§7.3), the **act log** (§8.5), and the **result card** (§10). Cards are `Frame`s with `AutomaticSize.Y` in a `UIListLayout`.
- **Plans view** (replaces the scroll content until Back): the last 10 records as rows `id · status · goal`; a row opens the record in the modal (JSON pretty-printed, split across labels like v1's `LABEL_MAX`).
- **Trash view:** rows with `Restore`; `Empty Trash` at the bottom with a confirm modal.
- **Modal host** reused for: plan step detail, destructive prompts, write batch view, revise note, confirms. Modals stay `Active=true` (v1 fix) so clicks never fall through.
- **Busy state:** `Plan`/`Approve` disabled and `Stop` shown while any phase runs; status line carries phase and budget.
- Design rules as v1: no emojis in UI, hover state on every button, `Enum.Font.Code` for source, RichText escaped `&` then `<` `>`.

---

## 14. File layout, build order, cut line

Banner sections after the change (BOOTSTRAP stays last, it wires everything):

```
1. CONFIG  2. SETTINGS  3. PROMPT & SKILLS  4. CONTEXT  5. PROVIDER  6. APPLY & RUN  7. UI
8. STORE   9. TOOLS     10. AGENT           11. GOAL UI  12. BOOTSTRAP
```

Hard boundaries: STORE knows instances and JSON, not models. TOOLS knows the DataModel and recordings, not HTTP. AGENT knows messages, budgets and phases, and calls TOOLS by name through a dispatch table. GOAL UI renders state and calls AGENT entry points (`Agent.plan`, `Agent.approve`, `Agent.stop`). PROVIDER changes (§6.2, §6.5) are the only edits inside v1 sections besides CONFIG constants, SETTINGS keys, and the top-bar toggle in UI.

**Build order:** STORE (+S4) → TOOLS read set → AGENT PLANNING + plan card → TOOLS write set + ACTING + act log (+S1, S5) → VERIFYING/REPAIRING (+S2, S3) → RECORDING + Plans/Trash views → settings group → classifier fix.

**Cut line:** after ACTING. A plugin that plans and edits with no auto-verify is still the assistant that was asked for; VERIFY ships behind its setting when S2/S3 pass.

**Dev loop:** unchanged from v1 (Plugin Debugging Enabled, Save and Reload, drop-in copy to `%LOCALAPPDATA%\Roblox\Plugins`). Expected size ≈ 1,500 new lines on top of 1,966.

---

## 15. Manual test checklist (per sitting, no automation pretense)

1. Fresh place, no store: press Plan with a goal → store folder appears with `RSP_StoreVersion=1`, plan card renders, Approve disabled until a step is ticked (all ticked by default).
2. Revise with a note → new plan differs and mentions the note.
3. Approve a 3-step plan → act log shows three `done` lines; Ctrl+Z three times reverts in reverse order; Ctrl+Y restores.
4. A step that edits a script open in the editor → the editor tab updates without reopening.
5. A step that trashes a Model → confirm modal appears; Allow → Model in Trash with `RSP_OrigPath`; Restore puts it back.
6. Careful on → every write prompts; Skip on one call → step still finishes with that call reported.
7. Verify on, a plan that introduces `error("boom")` on purpose → Run captures it, repair pass edits it, second run shows 0 errors, record says `repaired=true`.
8. Stop during ACT → current batch's recording cancelled, later steps `skipped`, record `status="stopped"`, no Run left active.
9. Groq keys only, goal on a large place → status shows Groq skipped for oversized requests and a clear message if no provider fits.
10. Plan next with Memory present → the proposal references systems named in Memory; Memory rewritten ≤ 6000 chars after RECORDING.
11. Save and Reload mid-phase → nothing stale reaches the UI or the place; store intact.
12. Open the place in a new Studio session → Plans list reads the records; a stale `#ref` in a record still resolves by path.

---

## 16. Deliberately NOT in v2

Streaming (`CreateWebStreamClient`, still a v3 candidate) · screenshots or Play-with-character (the plugin cannot; Studio MCP can) · `tool_choice` · multi-plan queues · a plan editor beyond include/exclude and Revise · cross-place or cross-machine memory · store migrations · model-callable `run_and_capture` · parallel step execution · diff rendering beyond changed-line counts and find/replace display · Chat-mode access to the tools · exporting plan records.

---

## 17. Verified-facts appendix (checked 2026-09-03)

| # | Fact | Source | Quote / note |
|---|---|---|---|
| A1 | Groq tool use supports `openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `llama-3.3-70b-versatile` (and others); parallel tool use | console.groq.com/docs/tool-use | "parallel tool use, where multiple tools can be called simultaneously" |
| A2 | Groq free tier, gpt-oss-120b and 20b: RPM 30 · RPD 1K · TPM 8K · TPD 200K; 429 on limit; headers `x-ratelimit-remaining-tokens`, `retry-after` | console.groq.com/docs/rate-limits | "our API returns a 429 Too Many Requests HTTP status code" |
| A3 | Groq documents **413 Request Entity Too Large** | console.groq.com/docs/errors | "The request body is too large. Please reduce the size of the request body." Whether an over-TPM single request is 413 or 429 is **not** documented → S6 |
| A4 | Cerebras Free Trial, gpt-oss-120b: RPM 5 · TPM 30K · TPH 1M · TPD 1M; every catalog model available on the free tier | inference-docs.cerebras.ai/support/rate-limits | page also mentions "$5 in free credits after adding a verified payment method"; not needed, not used ($0 rule) |
| A5 | Cerebras supports `tools`/`tool_calls`, `parallel_tool_calls`, and **strict mode** (`"strict": true` + `additionalProperties: false`) | inference-docs.cerebras.ai/capabilities/tool-use | "Strict mode ensures that the model generates tool call arguments that exactly match your defined schema" |
| A6 | Cerebras tool-use docs name only gpt-oss-120b; `zai-glm-4.7` unlisted | same | → `tools=false` for that entry until spiked |
| A7 | OpenRouter standardises tool calling; `provider.require_parameters` restricts to providers supporting all request params; `tools` is otherwise a *soft* preference | openrouter.ai/docs/guides/features/tool-calling · /docs/guides/routing/provider-selection | "only use providers that support all parameters in your request" |
| A8 | `RunService.Run`, `Pause`, `Stop` are **PluginSecurity** | create.roblox.com/docs/reference/engine/classes/RunService | no descriptive text on the page |
| A9 | Run mode "Starts simulating the game but does not insert your avatar"; Stop "resets all objects and instances to how they were before the playtest" | create.roblox.com/docs/studio/testing-modes | verbatim |
| A10 | `ScriptEditorService:UpdateSourceAsync(script, callback)`; docs silent on unopened scripts and undo | create.roblox.com/docs/reference/engine/classes/ScriptEditorService | → S1 |
| A11 | `Instance:GetDebugId(scopeLength=4)` is PluginSecurity, returns string | create.roblox.com/docs/reference/engine/classes/Instance | basis for `#ref` |
| A12 | `LogService.MessageOut(message, messageType, context)`; `GetLogHistory()`; docs silent on plugin/run-mode delivery | create.roblox.com/docs/reference/engine/classes/LogService | → S2 |
| A13 | `StringValue.Value`: no documented length cap | create.roblox.com/docs/reference/engine/classes/StringValue | → S4 |
| A14 | v1 classifier only maps "too large" on HTTP 400 (`classifyFailure`, PROVIDER section) | `studio-plugin/RoScriptPro.lua` @ `17db5c6` | → §6.5 |

**Unverified by design, spike-gated:** S1–S6 above. **Known-false-until-proven:** that Groq free-tier keys from different accounts are independent rate-limit buckets (multi-key assumption in §6.4 note 3); if they turn out to share an organisation bucket, the routing rule still holds and only the throughput multiplier shrinks.
