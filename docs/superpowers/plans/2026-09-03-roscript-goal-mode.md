# RoScript Pro Goal Mode (v2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Goal Mode to the single-file RoScript Pro Studio plugin: a plan → act → verify → record cycle driven by a native tool-calling loop, with a per-place context store, so Jasper can set a goal, approve a plan, have the plugin edit the workspace, and plan again from memory.

**Architecture:** Four new banner sections (STORE, TOOLS, AGENT, GOAL UI) are inserted before BOOTSTRAP in `studio-plugin/RoScriptPro.lua`. STORE owns `ServerStorage.RoScriptPro` (Memory, Manifest, Plans, Trash) and every write to it. TOOLS owns instance resolution, source reads, the property whitelist, and the read/write tool functions plus the recording-gated write executor. AGENT owns tool schemas, message assembly, budgets, cooldown waits, and the five phases. GOAL UI renders the second dock view and answers prompts through a `GoalUI` table forward-declared in CONFIG, the same pattern v1 uses for `UI`. PROVIDER gains an `opts` argument on `callProvider`/`chatOnce`, tool-call parsing, and the 413-first classifier fix.

**Tech Stack:** Luau (Roblox Studio plugin API: `ChangeHistoryService`, `ScriptEditorService`, `HttpService`, `LogService`, `RunService`, plugin settings), OpenAI-style chat-completions tool calling on Groq, Cerebras, OpenRouter free tiers. No build step, no external test runner.

**Spec:** `docs/superpowers/specs/2026-09-03-roscript-goal-mode-design.md` (rev 2, commit `9cae790`). Section references below (§n) point into it.

## Global Constraints

- **Single file.** All code lands in `studio-plugin/RoScriptPro.lua`. New sections are numbered `8. STORE`, `9. TOOLS`, `10. AGENT`, `11. GOAL UI`; the existing `8. BOOTSTRAP` banner becomes `12. BOOTSTRAP` (§14). BOOTSTRAP stays last.
- **Branch and worktree.** Implementation happens on `feature/goal-mode` in a fresh worktree `Downloads\Personal\gh\RoScript-Pro-wt\goal-mode`, created from `main` after PR #4 (spec + this plan) merges. Never commit to `main`; the PR is Jasper's to merge.
- **Every commit is shown first.** Each "Commit" step means: run `git diff`, show it to Jasper, wait for his explicit OK, then commit as `Jasper Paitan <jasper.paitan0918@gmail.com>` with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer. Never commit silently.
- **Test cycle in this environment.** There is no test runner. Pure logic is tested by the `SelfTest` block (Task 1) which runs on plugin load when `DEV = true` and prints `[RSP TEST] <name> PASS` or `FAIL <reason>` to Output. DataModel behaviour is tested in a scratch place. Reload = Studio settings "Plugin Debugging Enabled" once, then Ctrl+Shift+L. A task is done when its self-tests print PASS and its Studio check passes; `DEV` goes back to `false` before every commit.
- **Keys never enter the repo or chat.** Spike file `RSP_Spikes2.lua` lives in `Downloads\Personal\`, Jasper pastes keys into it locally, and deletes it after the sitting.
- **$0.** Free tiers only. Nothing in this plan calls a paid API.
- **Spec constants, verbatim** (§4–§6): `MEMORY_MAX = 6000`, `FACTS_MAX = 2500`, `NOTES_MAX = 3500`, `SUMMARY_MAX = 2000`, `CHUNK_MAX = 100000`, `PLANS_FED_TO_PLAN = 3`, `PLANS_KEEP = 20`, `TRASH_KEEP = 25`, `TRASH_DAYS = 14`, `INDEX_MAX_ENTRIES = 200`, `READ_SCRIPT_MAX = 8000`, `SEARCH_MAX_HITS = 40`, `OUTPUT_MAX_CHARS = 4000`, `STEP_SEED_MAX = 24000`, `WRITES_MAX_CHARS = 4000`, `MAX_STEPS = 10`, `MAX_CONSECUTIVE_TOOL_ERRORS = 3`, `GROQ_REQ_MAX = 3500` (S6 may change), `BIG_REQ_MAX = 28000`, `GOAL_WAIT_MAX = 90`, `GOAL_WAITS_PER_REQUEST = 2`, `CEREBRAS_MIN_GAP = 12`, `GOAL_TEMPERATURE = 0.2`, `GOAL_MAXTOK = { groq = 4096, cerebras = 8192, openrouter = 8192 }`, budgets table `normal`/`deep` per §6.3.
- **Invariants that every task preserves.** No recording ⇒ no write. No recording spans a model turn; `UpdateSourceAsync` is the one bounded yield allowed inside one, followed by a `gen` re-check. Only the coroutine that opened a recording finishes it. Store writes only while `RunService:IsEdit()`. The plugin never calls `RunService:Run()` or `Stop()`. The model never `Destroy`s.
- **UI rules** (v1): no emojis in UI, hover state on every button, `Enum.Font.Code` for source, RichText escaped `&` then `<` `>` via `escapeRich`.

---

## File structure

One file, sectioned. What each new section owns and what it may touch:

| Section | Owns | May call | Never touches |
|---|---|---|---|
| `1. CONFIG` (modify) | new constants, `PAT_BADTOOLCALL`, `GoalUI` forward table, `Goal` state table | – | – |
| `2. SETTINGS` (modify) | five new keys in `KNOWN` | – | – |
| `5. PROVIDER` (modify) | `callProvider(entry, messages, opts)`, `chatOnce(messages, state, statusFn, opts)`, `buildQueue(goalOnly)`, `MODEL_CHAIN[i].tools`, `PROV[p].strictTools`, classifier order | `KeyStore`, `Cooling`, `Bad` | DataModel, UI |
| `8. STORE` (new) | `ServerStorage.RoScriptPro` layout, chunking, FNV-1a, Memory/Manifest/Plans/Trash read+write, caps, `Store.withRecording` | `ChangeHistoryService`, `HttpService` JSON | HTTP, models, UI |
| `9. TOOLS` (new) | `Refs`, `Tools.resolve`, `Tools.readSource`, whitelist + encoders, `Tools.read.*`, `Tools.write.*`, `Executor.runWriteBatch` (pre-walk, prompts, recording) | `Store`, `GoalUI.prompt`, `ScriptEditorService`, `LogService` | HTTP |
| `10. AGENT` (new) | `Schemas`, message assembly, `estimateTokens`, `compactConvo`, `requestWithWaits`, `runToolBatch`, phases (`Agent.plan/revise/cancel/approve/retryStep/continueFrom/stop/startVerify/skipVerify`) | `chatOnce`, `Tools`, `Store`, `GoalUI` | Instances directly (always via TOOLS/STORE) |
| `11. GOAL UI` (new) | goal view, chips, plan card, act log, verify card, result card, Plans view, Trash view, prompt modal; fills `GoalUI` | `Agent.*`, `Store` (reads), v1 `mk`/`C`/`openModalPanel`/`closeModal`/`escapeRich`/`chunkText` | HTTP, recordings |
| `12. BOOTSTRAP` (modify) | Chat|Goal toggle wiring, `SelfTest.run()` when `DEV`, unload cleanup additions | everything | – |

Line anchors below are given as **"after `<exact existing line>`"** rather than line numbers, because every task shifts the file.

---

### Task 0: Spike plugin `RSP_Spikes2.lua` (gates S1–S6)

**Files:**
- Create (outside the repo, throwaway): `C:\Users\jaspe\Downloads\Personal\RSP_Spikes2.lua`
- Modify after the sitting: `docs/superpowers/specs/2026-09-03-roscript-goal-mode-design.md` §2 table (record results), and the constants in Task 1 that the results decide.

**Interfaces:**
- Consumes: nothing from the repo.
- Produces: six PASS/FAIL lines and the observations that set `GROQ_REQ_MAX`, `PROV[p].strictTools`, `MODEL_CHAIN[i].tools`, `CHUNK_MAX`, and the S1 write route.

- [ ] **Step 1: Write the spike plugin**

Jasper pastes his keys into `KEYS` locally. The file is never committed.

```lua
-- RSP_Spikes2.lua — THROWAWAY. Paste keys below, copy to %LOCALAPPDATA%\Roblox\Plugins,
-- restart Studio, open a scratch place, read Output. Delete this file afterwards.
local KEYS = { groq = "", cerebras = "", openrouter = "" } -- paste, never commit

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function out(tag, ok, detail)
	print(("[RSP SPIKES2] %s %s %s"):format(tag, ok and "PASS" or "FAIL", detail or ""))
end

-- S1: UpdateSourceAsync inside a recording, unopened script; does it yield; does it undo.
local function s1()
	local s = Instance.new("Script")
	s.Name = "RSP_S1"
	s.Source = "-- before"
	s.Parent = ServerScriptService
	local rec = ChangeHistoryService:TryBeginRecording("RSP S1")
	if not rec then out("S1", false, "no recording"); return end
	local yielded = true
	local conn
	conn = RunService.Heartbeat:Once(function() yielded = true end)
	local returnedSameFrame = false
	local ok, err = pcall(function()
		local t0 = os.clock()
		ScriptEditorService:UpdateSourceAsync(s, function(old) return old .. "\n-- after" end)
		returnedSameFrame = (os.clock() - t0) < 0.001
	end)
	ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
	local landed = s.Source:find("-- after", 1, true) ~= nil
	out("S1", ok and landed, ("landed=%s sameFrame=%s err=%s  -> now press Ctrl+Z once and check RSP_S1.Source reverted"):format(tostring(landed), tostring(returnedSameFrame), tostring(err)))
end

-- S2/S3 helper: a script that prints, warns, errors on run.
local function makeNoisyScript()
	local s = Instance.new("Script")
	s.Name = "RSP_Noisy"
	s.Source = 'print("RSP_S2 print"); warn("RSP_S2 warn"); local p = Instance.new("Part"); p.Name = "RSP_RunPart"; p.Parent = workspace; error("RSP_S2 error")'
	s.Parent = ServerScriptService
	return s
end

-- S2 + S3: arm capture; Jasper presses Run (F8), waits 5 s, presses Stop.
local function s2s3()
	makeNoisyScript()
	local v = Instance.new("StringValue"); v.Name = "RSP_S3Value"; v.Value = "before"; v.Parent = ServerStorage
	local rec = ChangeHistoryService:TryBeginRecording("RSP S3 pre-run edit")
	v.Value = "edited-before-run"
	ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
	local heldRef = v
	local boundary = os.time()
	local got = {}
	local conn = LogService.MessageOut:Connect(function(msg, mtype)
		if msg:find("RSP_S2", 1, true) then table.insert(got, mtype.Name .. ": " .. msg) end
	end)
	print("[RSP SPIKES2] S2/S3 armed. Press Run (F8), wait 5 seconds, press Stop.")
	local wasRunning, sawRunMode = false, nil
	local hb
	hb = RunService.Heartbeat:Connect(function()
		if RunService:IsRunning() then
			wasRunning = true
			if sawRunMode == nil then sawRunMode = RunService:IsRunMode() end
		elseif wasRunning and RunService:IsEdit() then
			hb:Disconnect(); conn:Disconnect()
			local hist = LogService:GetLogHistory()
			local viaHistory = 0
			for _, e in ipairs(hist) do
				if e.timestamp >= boundary - 1 and tostring(e.message):find("RSP_S2", 1, true) then viaHistory += 1 end
			end
			out("S2", #got >= 2, ("MessageOut lines=%d  history lines=%d  ringSize=%d"):format(#got, viaHistory, #hist))
			local partGone = workspace:FindFirstChild("RSP_RunPart") == nil
			local refOk = heldRef.Parent == ServerStorage and heldRef.Value == "edited-before-run"
			local rec2 = ChangeHistoryService:TryBeginRecording("RSP S3 post")
			local recOk = rec2 ~= nil
			if rec2 then ChangeHistoryService:FinishRecording(rec2, Enum.FinishRecordingOperation.Cancel) end
			out("S3", partGone and refOk and recOk, ("runPartGone=%s refIntact=%s recordingAfter=%s IsRunModeDuringRun=%s  -> now Ctrl+Z: RSP_S3Value.Value must revert to 'before'"):format(tostring(partGone), tostring(refOk), tostring(recOk), tostring(sawRunMode)))
		end
	end)
end

-- S4: StringValue chunk sizes.
local function s4()
	local v = Instance.new("StringValue"); v.Name = "RSP_S4"; v.Parent = ServerStorage
	local results = {}
	for _, n in ipairs({ 100000, 150000 }) do
		local ok = pcall(function() v.Value = string.rep("x", n) end)
		table.insert(results, ("%d=%s/%s"):format(n, tostring(ok), tostring(ok and #v.Value == n)))
	end
	out("S4", true, table.concat(results, " "))
	v:Destroy()
end

-- S5: exact production-shaped tool request per provider.
local URLS = {
	groq = "https://api.groq.com/openai/v1/chat/completions",
	cerebras = "https://api.cerebras.ai/v1/chat/completions",
	openrouter = "https://openrouter.ai/api/v1/chat/completions",
}
local MODELS = { groq = "openai/gpt-oss-120b", cerebras = "gpt-oss-120b", openrouter = "openai/gpt-oss-120b:free" }

local function toolSet(strict)
	local function fn(name, desc, props, required)
		local f = { name = name, description = desc, parameters = { type = "object", properties = props, required = required, additionalProperties = false } }
		if strict then f.strict = true end
		return { type = "function", ["function"] = f }
	end
	return {
		fn("index", "List children of a path", { path = { type = "string" }, depth = { type = { "integer", "null" } } }, { "path", "depth" }),
		fn("read_memory", "Read project memory", { reason = { type = "string" } }, { "reason" }),
		fn("set_props", "Set properties", { targets = { type = "array", items = { type = "string" } }, props = { type = "array", items = { type = "object", properties = { name = { type = "string" }, value = { type = "string" } }, required = { "name", "value" }, additionalProperties = false } } }, { "targets", "props" }),
	}
end

local function post(p, body)
	local headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. KEYS[p] }
	if p == "openrouter" then headers["HTTP-Referer"] = "https://github.com/jasper-0918/RoScript-Pro"; headers["X-Title"] = "RSP Spikes" end
	local ok, resp = pcall(function()
		return HttpService:RequestAsync({ Url = URLS[p], Method = "POST", Headers = headers, Body = HttpService:JSONEncode(body) })
	end)
	if not ok then return nil, tostring(resp) end
	return resp
end

local function s5(p)
	if KEYS[p] == "" then out("S5-" .. p, false, "no key"); return end
	local strict = (p == "cerebras")
	local body = {
		model = MODELS[p], temperature = 0.2, max_tokens = 1024,
		messages = { { role = "system", content = "You are a tool-using agent. Always call a tool." }, { role = "user", content = "Call read_memory, then index game at depth 1." } },
		tools = toolSet(strict),
	}
	if p ~= "openrouter" then body.parallel_tool_calls = true; body.reasoning_effort = "low" else body.provider = { require_parameters = true } end
	local resp, err = post(p, body)
	if not resp then out("S5-" .. p, false, err); return end
	if not resp.Success then out("S5-" .. p, false, resp.StatusCode .. " " .. resp.Body:sub(1, 300)); return end
	local d = HttpService:JSONDecode(resp.Body)
	local msg = d.choices and d.choices[1] and d.choices[1].message
	local tc = msg and msg.tool_calls and msg.tool_calls[1]
	if not tc then out("S5-" .. p, false, "no tool_calls: " .. resp.Body:sub(1, 300)); return end
	-- round trip: assistant message (with reasoning) + tool result
	local msgs = body.messages
	table.insert(msgs, { role = "assistant", content = msg.content, tool_calls = msg.tool_calls, reasoning = msg.reasoning })
	for _, c in ipairs(msg.tool_calls) do
		table.insert(msgs, { role = "tool", tool_call_id = c.id, content = HttpService:JSONEncode({ ok = true, result = "stub" }) })
	end
	local resp2 = post(p, body)
	out("S5-" .. p, resp2 and resp2.Success, ("first=%s name=%s argsType=%s  roundtrip=%s parallelCalls=%d reasoning=%s"):format(resp.StatusCode, tc["function"].name, type(tc["function"].arguments), resp2 and resp2.StatusCode or "err", #msg.tool_calls, tostring(msg.reasoning ~= nil)))
end

-- S6: oversized request on Groq.
local function s6()
	if KEYS.groq == "" then out("S6", false, "no key"); return end
	local big = string.rep("The quick brown fox jumps over the lazy dog. ", 1000) -- ~10K tokens
	local resp, err = post("groq", { model = MODELS.groq, max_tokens = 4096, messages = { { role = "user", content = big } } })
	if not resp then out("S6", false, err); return end
	local body = resp.Body or ""
	local lower = body:lower()
	out("S6", true, ("status=%d rateLimitPattern=%s tooLargePattern=%s body=%s"):format(resp.StatusCode, tostring(lower:find("rate.?limit") ~= nil), tostring(lower:find("request too large") ~= nil or lower:find("body is too large") ~= nil), body:sub(1, 400)))
end

task.spawn(function()
	s1(); s4()
	for _, p in ipairs({ "groq", "cerebras", "openrouter" }) do s5(p) end
	s6()
	s2s3()
end)
```

- [ ] **Step 2: Jasper runs the sitting**

Copy the file into `%LOCALAPPDATA%\Roblox\Plugins`, restart Studio, open a scratch place with Output visible. Read the S1, S4, S5-*, S6 lines. Then press F8, wait 5 s, press Stop; read S2/S3. Press Ctrl+Z twice and check `RSP_S1.Source` and `RSP_S3Value.Value` reverted as the lines instruct. Paste all `[RSP SPIKES2]` lines into chat.

- [ ] **Step 3: Record results and set constants**

For each spike, fill the outcome into the spec's §2 table (a new "Result 2026-09-xx" column) and apply the fallbacks the table names:
- S1 landed but no undo → Task 7 routes unopened scripts through `.Source`.
- S2 `MessageOut lines=0` → Task 10 uses the history diff only.
- S3 any `false` → `goal_verify_enabled` default `false` in Task 1.
- S4 150000 false → `CHUNK_MAX = 50000`.
- S5 provider 400 on strict → that provider's `strictTools=false`; other 400 → drop the named parameter for that provider; still failing → `tools=false` on its chain entries.
- S6 `rateLimitPattern=true` → the 413-first order in Task 4 is load-bearing (it already is). If the 413 body's "Requested N" ≈ 10K + 4096 → `GROQ_REQ_MAX = 3904`; if ≈ 10K → `7000`.

- [ ] **Step 4: Delete the spike file**

```powershell
Remove-Item "$env:LOCALAPPDATA\Roblox\Plugins\RSP_Spikes2.lua"; Remove-Item "$env:USERPROFILE\Downloads\Personal\RSP_Spikes2.lua"
```
Also delete `RSP_S1`, `RSP_Noisy`, `RSP_S3Value` from the scratch place, or discard the place.

- [ ] **Step 5: Commit the spec's results column**

Show the diff of the spec; on Jasper's OK:
```bash
git add docs/superpowers/specs/2026-09-03-roscript-goal-mode-design.md
git commit -m "spec: record spike S1-S6 results"
```

---

### Task 1: Scaffold — constants, settings keys, forward tables, section banners, SelfTest harness

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` sections `1. CONFIG`, `2. SETTINGS`, `8. BOOTSTRAP` (renamed `12. BOOTSTRAP`); insert four empty banner sections before it.

**Interfaces:**
- Consumes: v1's `trace`, `S`, `DEV`.
- Produces: constants listed in Global Constraints; `PAT_BADTOOLCALL`; `GoalUI` table with no-op defaults `{ log(text, kind), setPhase(phase, detail), prompt(kind, payload) -> "allow"|"skip"|"stop", showCard(kind, data), refreshPlans(), setBusy(busy) }`; `Goal` state table; `SelfTest.case(name, fn)` and `SelfTest.run()`; `BUDGETS` with `budgetFor(effort)`.

- [ ] **Step 1: Add the failing self-test harness call**

In BOOTSTRAP, right after `trace("RoScript Pro loaded")`, add:
```lua
if DEV then
	SelfTest.run()
end
```
Set `local DEV = true` temporarily. Reload (Ctrl+Shift+L). Expected: Output shows an error `attempt to index nil with 'run'` (SelfTest does not exist yet). That is the red.

- [ ] **Step 2: Add constants to CONFIG**

After the line `local RUN_ENGINE = "loadstring"` add:
```lua
-- ─── Goal Mode (v2) constants — spec §4–§6, do not tune without re-reading ───
local STORE_VERSION = 1
local MEMORY_MAX, FACTS_MAX, NOTES_MAX, SUMMARY_MAX = 6000, 2500, 3500, 2000
local CHUNK_MAX = 100000 -- S4 confirms; documented StringValue cap is 200,000
local PLANS_FED_TO_PLAN, PLANS_KEEP, TRASH_KEEP, TRASH_DAYS = 3, 20, 25, 14
local INDEX_MAX_ENTRIES, READ_SCRIPT_MAX, SEARCH_MAX_HITS, OUTPUT_MAX_CHARS = 200, 8000, 40, 4000
local STEP_SEED_MAX, WRITES_MAX_CHARS = 24000, 4000
local MAX_STEPS, MAX_CONSECUTIVE_TOOL_ERRORS = 10, 3
local GROQ_REQ_MAX = 3500 -- S6 sets: 8000 - GOAL_MAXTOK.groq if max_tokens counts, else 7000
local BIG_REQ_MAX = 28000 -- Cerebras 30K TPM
local GOAL_WAIT_MAX, GOAL_WAITS_PER_REQUEST, CEREBRAS_MIN_GAP = 90, 2, 12
local GOAL_TEMPERATURE = 0.2
local GOAL_MAXTOK = { groq = 4096, cerebras = 8192, openrouter = 8192 }
local BUDGETS = {
	normal = { plan = 12, revise = 6, act = 8, repair = 6, repairPasses = 1, tokens = 150000 },
	deep = { plan = 24, revise = 12, act = 16, repair = 12, repairPasses = 2, tokens = 300000 },
}
local function budgetFor(effort)
	return BUDGETS[effort] or BUDGETS.normal
end
local PAT_BADTOOLCALL = { "tool_use_failed", "failed_generation" }

-- Upward interface TOOLS/AGENT → GOAL UI. Section 11 fills these (same pattern as UI).
local GoalUI = {
	log = function(text, kind) end, -- kind: "info" | "muted" | "error" | "ok"
	setPhase = function(phase, detail) end,
	prompt = function(kind, payload) return "allow" end, -- "allow" | "skip" | "stop"
	showCard = function(kind, data) end, -- "plan" | "verify" | "result"
	refreshPlans = function() end,
	setBusy = function(busy) end,
}

-- Goal Mode session state. AGENT owns it; GOAL UI reads it.
local Goal = {
	phase = "IDLE", -- IDLE | PLANNING | AWAITING_APPROVAL | ACTING | VERIFYING | REPAIRING | RECORDING
	gen = 0, -- Goal Mode's own generation counter (Chat keeps `gen`)
	plan = nil, -- the submitted plan object
	planConvo = nil, -- PLANNING transcript kept for Revise
	revisions = {},
	steps = {}, -- per-step bookkeeping: { n, status, outcome, changed, writes, undoLabels }
	verify = nil,
	goalText = "",
	models = {},
	estTokens = 0,
	requests = {}, -- provider -> count this session
	openRecording = nil, -- { id, owner = coroutine }
	stepConvo = nil,
}
```

Give `MODEL_CHAIN` its `tools` flags and `PROV` its strict flags (edit in place):
```lua
local PROV = {
	groq = { name = "Groq", url = "https://api.groq.com/openai/v1/chat/completions", strictTools = false },
	cerebras = { name = "Cerebras", url = "https://api.cerebras.ai/v1/chat/completions", strictTools = true },
	openrouter = { name = "OpenRouter", url = "https://openrouter.ai/api/v1/chat/completions", strictTools = false },
}
```
```lua
local MODEL_CHAIN = {
	{ p = "groq", m = "openai/gpt-oss-120b", tools = true },
	{ p = "groq", m = "openai/gpt-oss-20b", tools = true },
	{ p = "cerebras", m = "gpt-oss-120b", tools = true },
	{ p = "cerebras", m = "zai-glm-4.7", tools = false }, -- absent from Cerebras docs 2026-09-03
	{ p = "openrouter", m = "openai/gpt-oss-120b:free", tools = true }, -- S5: endpoints may be empty
	{ p = "openrouter", m = "openai/gpt-oss-20b:free", tools = true },
	{ p = "openrouter", m = "nvidia/nemotron-3-super-120b-a12b:free", tools = false },
	{ p = "openrouter", m = "meta-llama/llama-3.3-70b-instruct:free", tools = false },
}
```
Apply S5's results to these flags.

- [ ] **Step 3: Add settings keys**

In SETTINGS, change `KNOWN` to:
```lua
local KNOWN = { "keys_groq", "keys_openrouter", "keys_cerebras", "ctx_enabled", "active_skills",
	"goal_mode", "goal_focus", "goal_verify_enabled", "goal_careful", "goal_effort" }
```
Defaults are applied at read sites: `S.get("goal_focus", { bugs = true, quality = true })`, `S.get("goal_verify_enabled", true)` (or `false` if S3 failed), `S.get("goal_careful", false)`, `S.get("goal_effort", "normal")`, `S.get("goal_mode", false)`.

- [ ] **Step 4: Insert the banners and the SelfTest harness**

Immediately before the line `-- ═══════════════════════ 8. BOOTSTRAP ═══════════════════════` insert:
```lua
-- ═══════════════════════ 8. STORE ═══════════════════════

-- ═══════════════════════ 9. TOOLS ═══════════════════════

-- ═══════════════════════ 10. AGENT ═══════════════════════

-- ═══════════════════════ 11. GOAL UI ═══════════════════════

-- ─── SelfTest: DEV-only assertions, printed on load. Cases are added by each section. ───
local SelfTest = { cases = {} }
function SelfTest.case(name, fn)
	table.insert(SelfTest.cases, { name = name, fn = fn })
end
function SelfTest.run()
	local pass, fail = 0, 0
	for _, c in ipairs(SelfTest.cases) do
		local ok, err = pcall(c.fn)
		if ok then
			pass += 1
			print("[RSP TEST]", c.name, "PASS")
		else
			fail += 1
			print("[RSP TEST]", c.name, "FAIL", tostring(err))
		end
	end
	print(("[RSP TEST] %d passed, %d failed"):format(pass, fail))
end
-- Scratch folder for DataModel-touching cases; destroyed at the end of every case.
local function withScratch(fn)
	local f = Instance.new("Folder")
	f.Name = "RSP_TestScratch"
	f.Parent = game:GetService("ServerStorage")
	local ok, err = pcall(fn, f)
	f:Destroy()
	assert(ok, err)
end
SelfTest.case("harness runs", function()
	assert(budgetFor("deep").plan == 24, "deep plan budget")
	assert(budgetFor("nonsense").plan == 12, "default budget")
end)
```
Rename the existing BOOTSTRAP banner to `-- ═══════════════════════ 12. BOOTSTRAP ═══════════════════════`. Move the `SelfTest` block so it sits **before** section 8 STORE (the sections add cases below their code), i.e. place the `-- ─── SelfTest` block directly under the `8. STORE` banner line, then the STORE code follows in Task 2.

- [ ] **Step 5: Reload and verify green**

Reload. Expected Output:
```
[RSP TEST] harness runs PASS
[RSP TEST] 1 passed, 0 failed
```
Also confirm the Chat still answers one message (no regression from the `PROV`/`MODEL_CHAIN` edits).

- [ ] **Step 6: Update the header comment and commit**

Change the header block's first line to `RoScript Pro — Studio plugin v2 (Goal Mode)` and add the spec path line `Spec v2: docs/superpowers/specs/2026-09-03-roscript-goal-mode-design.md`. Set `DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: scaffold constants, settings keys, GoalUI/Goal tables, SelfTest harness"
```

---

### Task 2: STORE — the context folder

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `8. STORE` (below the SelfTest block).

**Interfaces:**
- Consumes: `ServerStorage`, `HttpService`, `ChangeHistoryService`, `RunService` (add `local RunService = game:GetService("RunService")` and `local LogService = game:GetService("LogService")` to CONFIG services), constants from Task 1, `trace`, `utf8Trim`.
- Produces (all in `local Store = {}`):
  - `Store.inEdit() -> boolean`
  - `Store.withRecording(label: string, fn: () -> ()) -> ok: boolean, err: string?` — opens/commits its own recording around `fn`; cancels on throw; returns `false, "undo unavailable"` if no recording; refuses when not in edit mode.
  - `Store.hash(s: string) -> string` (8 hex chars, FNV-1a 32)
  - `Store.ensure() -> Folder?, err: string?` (creates layout; refuses on version mismatch)
  - `Store.readText(folder: Folder) -> string`, `Store.writeText(folder: Folder, text: string)` (chunked)
  - `Store.readMemory() -> facts: string, notes: string`, `Store.writeMemory(facts, notes)`
  - `Store.readManifest() -> { [path]: hash }`, `Store.writeManifest(map)`
  - `Store.nextPlanId(title: string) -> string`
  - `Store.listPlans(offset: number?) -> { {id, status, createdAt, goal} }, total: number` (newest first, 10 per page)
  - `Store.readPlan(id) -> record?, err?`
  - `Store.writePlan(record, beforeSources: { [k: number]: string })`
  - `Store.applyCaps()`
  - `Store.trash(inst: Instance, planId: string)`, `Store.trashItems() -> {Instance}`, `Store.restore(item: Instance, choice: "rename"|"replace"|nil) -> ok, err`, `Store.emptyTrash()`
  - Manifest and Memory are written **inside the caller's recording** (RECORDING opens one recording for everything); `Store.writePlan` likewise. Only `Store.restore`/`emptyTrash` open their own.

- [ ] **Step 1: Write the failing self-tests**

Under the SelfTest block in section 8, add:
```lua
SelfTest.case("store: fnv1a known vectors", function()
	assert(Store.hash("") == "811c9dc5", "empty -> offset basis, got " .. Store.hash(""))
	assert(Store.hash("a") == "e40c292c", "'a', got " .. Store.hash("a"))
	assert(Store.hash("hello") ~= Store.hash("hellp"), "distinct")
end)
SelfTest.case("store: chunk round trip past CHUNK_MAX", function()
	withScratch(function(f)
		local text = string.rep("y", CHUNK_MAX + 17)
		Store.writeText(f, text)
		assert(#f:GetChildren() == 2, "two chunks, got " .. #f:GetChildren())
		assert(Store.readText(f) == text, "round trip")
		Store.writeText(f, "short")
		assert(#f:GetChildren() == 1, "surplus chunk deleted")
		assert(Store.readText(f) == "short", "overwrite")
	end)
end)
SelfTest.case("store: plan id slug", function()
	local id = Store.nextPlanId("Fix the Shop's Errors!! Now")
	assert(id:match("^Plan_%d%d%d_fix%-the%-shop%-s%-errors%-%-now$") or id:match("^Plan_%d%d%d_fix%-the%-shop"), id)
	assert(#id <= 40, "length " .. #id)
end)
```
Reload with `DEV = true`. Expected: three FAIL lines (`attempt to index nil with 'hash'` etc.).

- [ ] **Step 2: Implement STORE**

```lua
local Store = {}
do
	local ROOT_NAME = "RoScriptPro"

	function Store.inEdit()
		return RunService:IsEdit()
	end

	-- FNV-1a 32-bit, hex. Luau has no hashing built in.
	function Store.hash(s)
		local h = 2166136261
		for i = 1, #s do
			h = bit32.bxor(h, s:byte(i))
			h = bit32.band(h * 16777619, 0xFFFFFFFF)
			-- (h * prime) can exceed 2^53 only if h > ~5e8 * ...; bit32.band on a float is fine below 2^53,
			-- and 0xFFFFFFFF * 16777619 < 2^53, so this stays exact.
		end
		return string.format("%08x", h)
	end

	function Store.withRecording(label, fn)
		if not Store.inEdit() then
			return false, "not in edit mode"
		end
		local rec = ChangeHistoryService:TryBeginRecording("RoScriptPro " .. label, "RoScript Pro: " .. label)
		if not rec then
			return false, "undo unavailable"
		end
		local ok, err = pcall(fn)
		ChangeHistoryService:FinishRecording(rec, ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
		if not ok then
			return false, tostring(err)
		end
		return true
	end

	local function child(parent, name, class)
		local c = parent:FindFirstChild(name)
		if not c then
			c = Instance.new(class or "Folder")
			c.Name = name
			c.Parent = parent
		end
		return c
	end

	function Store.root()
		return ServerStorage:FindFirstChild(ROOT_NAME)
	end

	function Store.ensure()
		local root = Store.root()
		if root then
			local v = root:GetAttribute("RSP_StoreVersion")
			if v ~= STORE_VERSION then
				return nil, ("store version %s found, this plugin expects %d; Goal Mode refuses to start"):format(tostring(v), STORE_VERSION)
			end
		else
			root = Instance.new("Folder")
			root.Name = ROOT_NAME
			root:SetAttribute("RSP_StoreVersion", STORE_VERSION)
			root.Parent = ServerStorage
		end
		child(root, "Memory"); child(root, "Manifest"); child(root, "Plans"); child(root, "Trash")
		return root
	end

	-- Chunked text in StringValues chunk_1..n.
	function Store.readText(folder)
		local parts = {}
		local i = 1
		while true do
			local c = folder:FindFirstChild("chunk_" .. i)
			if not c then break end
			parts[i] = c.Value
			i += 1
		end
		return table.concat(parts)
	end

	function Store.writeText(folder, text)
		local n = 0
		local pos = 1
		repeat
			n += 1
			local c = child(folder, "chunk_" .. n, "StringValue")
			c.Value = text:sub(pos, pos + CHUNK_MAX - 1)
			pos += CHUNK_MAX
		until pos > #text
		local k = n + 1
		while true do
			local extra = folder:FindFirstChild("chunk_" .. k)
			if not extra then break end
			extra:Destroy()
			k += 1
		end
	end

	-- Memory = "<facts>\n<<<NOTES>>>\n<notes>"
	local SEP = "\n<<<NOTES>>>\n"
	function Store.readMemory()
		local root = Store.root()
		if not root then return "", "" end
		local text = Store.readText(root.Memory)
		local a, b = text:find(SEP, 1, true)
		if not a then return text, "" end
		return text:sub(1, a - 1), text:sub(b + 1)
	end
	function Store.writeMemory(facts, notes)
		local root = Store.ensure()
		Store.writeText(root.Memory, utf8Trim(facts, FACTS_MAX) .. SEP .. utf8Trim(notes, NOTES_MAX))
	end

	function Store.readManifest()
		local root = Store.root()
		if not root then return {} end
		local text = Store.readText(root.Manifest)
		if #text == 0 then return {} end
		local ok, map = pcall(function() return HttpService:JSONDecode(text) end)
		return ok and type(map) == "table" and map or {}
	end
	function Store.writeManifest(map)
		local root = Store.ensure()
		Store.writeText(root.Manifest, HttpService:JSONEncode(map))
	end

	local function slug(title)
		local s = title:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
		return s:sub(1, 30):gsub("%-+$", "")
	end
	function Store.nextPlanId(title)
		local root = Store.root()
		local maxN = 0
		if root then
			for _, p in ipairs(root.Plans:GetChildren()) do
				local n = tonumber(p.Name:match("^Plan_(%d+)_"))
				if n and n > maxN then maxN = n end
			end
		end
		return ("Plan_%03d_%s"):format(maxN + 1, slug(title))
	end

	function Store.listPlans(offset)
		offset = offset or 0
		local root = Store.root()
		if not root then return {}, 0 end
		local all = {}
		for _, p in ipairs(root.Plans:GetChildren()) do
			table.insert(all, { id = p.Name, status = p:GetAttribute("RSP_Status") or "?", createdAt = p:GetAttribute("RSP_CreatedAt") or 0, goal = p:GetAttribute("RSP_Goal") or "" })
		end
		table.sort(all, function(a, b) return a.createdAt > b.createdAt end)
		local page = {}
		for i = offset + 1, math.min(offset + 10, #all) do
			table.insert(page, all[i])
		end
		return page, #all
	end

	function Store.readPlan(id)
		local root = Store.root()
		local p = root and root.Plans:FindFirstChild(id)
		if not p then return nil, "no such plan" end
		local ok, rec = pcall(function() return HttpService:JSONDecode(Store.readText(p)) end)
		if not ok or type(rec) ~= "table" then return nil, "unreadable record" end
		return rec
	end

	-- Caller holds the recording. beforeSources: k -> source text for changed[].before = "before/k".
	function Store.writePlan(record, beforeSources)
		local root = Store.ensure()
		local p = child(root.Plans, record.id)
		p:SetAttribute("RSP_Status", record.status)
		p:SetAttribute("RSP_CreatedAt", record.createdAt)
		p:SetAttribute("RSP_Goal", utf8Trim(record.goal or "", 200))
		Store.writeText(p, HttpService:JSONEncode(record))
		local before = child(p, "before")
		for k, src in pairs(beforeSources or {}) do
			Store.writeText(child(before, tostring(k)), src)
		end
	end

	function Store.applyCaps()
		local root = Store.root()
		if not root then return end
		local plans = root.Plans:GetChildren()
		table.sort(plans, function(a, b) return (a:GetAttribute("RSP_CreatedAt") or 0) > (b:GetAttribute("RSP_CreatedAt") or 0) end)
		for i = PLANS_KEEP + 1, #plans do
			plans[i]:Destroy()
			GoalUI.log("pruned old record " .. plans[i].Name, "muted")
		end
		local items = root.Trash:GetChildren()
		table.sort(items, function(a, b) return (a:GetAttribute("RSP_TrashedAt") or 0) > (b:GetAttribute("RSP_TrashedAt") or 0) end)
		local cutoff = os.time() - TRASH_DAYS * 86400
		for i, it in ipairs(items) do
			if i > TRASH_KEEP or (it:GetAttribute("RSP_TrashedAt") or 0) < cutoff then
				GoalUI.log("emptied old trash item " .. it.Name, "muted")
				it:Destroy()
			end
		end
	end

	-- Inside the step's recording (caller holds it).
	function Store.trash(inst, planId)
		local root = Store.ensure()
		inst:SetAttribute("RSP_OrigParent", inst.Parent and inst.Parent:GetFullName() or "")
		inst:SetAttribute("RSP_OrigName", inst.Name)
		inst:SetAttribute("RSP_Plan", planId or "")
		inst:SetAttribute("RSP_TrashedAt", os.time())
		inst.Parent = root.Trash
	end
	function Store.trashItems()
		local root = Store.root()
		return root and root.Trash:GetChildren() or {}
	end
	-- choice: nil (fail on conflict), "rename", "replace". Opens its own recording.
	function Store.restore(item, choice)
		return Store.withRecording("restore", function()
			local parentPath = item:GetAttribute("RSP_OrigParent") or ""
			local parent = walkPath(parentPath) or workspace
			local name = item:GetAttribute("RSP_OrigName") or item.Name
			local clash = parent:FindFirstChild(name)
			if clash and clash ~= item then
				if choice == "rename" then
					name = name .. "_restored"
				elseif choice == "replace" then
					Store.trash(clash, "restore-replace")
				else
					error("conflict: a sibling named " .. name .. " exists")
				end
			end
			item.Name = name
			item.Parent = parent
			for _, a in ipairs({ "RSP_OrigParent", "RSP_OrigName", "RSP_Plan", "RSP_TrashedAt" }) do
				item:SetAttribute(a, nil)
			end
		end)
	end
	function Store.emptyTrash()
		return Store.withRecording("empty trash", function()
			for _, it in ipairs(Store.trashItems()) do
				it:Destroy() -- the only Destroy of user content in the plugin; Jasper confirmed the modal
			end
		end)
	end
end
```
`walkPath` is v1's (section 6). Because STORE sits after section 6 in the file, it is in scope.

- [ ] **Step 3: Reload and verify green**

Expected Output: the three `store:` cases PASS plus `harness runs`. Then in the scratch place run from the command bar:
```lua
local p = require -- (not needed) — instead: reload with DEV and add a temporary case:
```
Instead of the command bar, add a fourth self-test and keep it:
```lua
SelfTest.case("store: ensure + plan write/read/list", function()
	local existing = ServerStorage:FindFirstChild("RoScriptPro")
	assert(existing == nil, "run this test in a place with no store yet")
	local root = assert(Store.ensure())
	local ok = Store.withRecording("test", function()
		Store.writePlan({ v = 1, id = "Plan_001_test", status = "done", createdAt = os.time(), goal = "g", steps = {}, summary = "s" }, { [1] = "-- before source" })
		Store.writeMemory("FACTS", "NOTES")
		Store.writeManifest({ ["ServerScriptService.X"] = "deadbeef" })
	end)
	assert(ok, "recording write")
	local page, total = Store.listPlans(0)
	assert(total == 1 and page[1].id == "Plan_001_test", "list")
	local rec = assert(Store.readPlan("Plan_001_test"))
	assert(rec.summary == "s", "record")
	assert(Store.readText(root.Plans.Plan_001_test.before["1"]) == "-- before source", "before chunk")
	local f, n = Store.readMemory()
	assert(f == "FACTS" and n == "NOTES", "memory")
	assert(Store.readManifest()["ServerScriptService.X"] == "deadbeef", "manifest")
	assert(Store.nextPlanId("Next") == "Plan_002_next", Store.nextPlanId("Next"))
	root:Destroy()
end)
```
Reload in a fresh scratch place. Expected: all `store:` cases PASS; Ctrl+Z is available once (the test recording) and undoing it recreates nothing since the root was destroyed after (acceptable for a test).

- [ ] **Step 4: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: STORE section (chunked store, memory, manifest, plan records, trash, caps)"
```

---

### Task 3: TOOLS — refs, source reads, whitelist encoders, the read tool set

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `9. TOOLS`.

**Interfaces:**
- Consumes: `Store`, `walkPath`, `summarizeInstance`, `buildSelectionSummary` (v1), `utf8Trim`, `LogService`, `ScriptEditorService`, `Selection`, constants.
- Produces (`local Tools = {}`):
  - `Tools.ref(inst: Instance) -> string` (`"#r17"`, stable per instance per session)
  - `Tools.resolve(target: string) -> Instance?, err: string?` (ref first with `IsDescendantOf(game)`, then path)
  - `Tools.readSource(script: LuaSourceContainer) -> string` (editor source, `.Source` fallback)
  - `Tools.hashOf(script) -> string`
  - `Tools.encodeValue(v: any) -> any` (JSON-friendly), `Tools.decodeValue(str: string, expected: string) -> any?, err?`
  - `WHITELIST: { [className]: { [prop]: typeName } }` plus `Tools.propsFor(inst) -> { [prop]: typeName }` (walks `IsA` chain)
  - `Tools.read = { index, inspect, read_script, search, read_output, read_memory, list_plans, read_plan }`, each `(args: table) -> table` returning `{ ok = true, ... }` or `{ ok = false, error = string }`
  - `Tools.clearRefs()`

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("tools: refs are unique and resolve", function()
	withScratch(function(f)
		local a = Instance.new("Part"); a.Name = "Part"; a.Parent = f
		local b = Instance.new("Part"); b.Name = "Part"; b.Parent = f
		local ra, rb = Tools.ref(a), Tools.ref(b)
		assert(ra ~= rb, "distinct refs for same-named siblings")
		assert(Tools.ref(a) == ra, "stable")
		assert(Tools.resolve(ra) == a and Tools.resolve(rb) == b, "resolve by ref")
		assert(Tools.resolve("ServerStorage.RSP_TestScratch") == f, "resolve by path")
		b:Destroy()
		local inst, err = Tools.resolve(rb)
		assert(inst == nil and err:find("stale"), "destroyed ref is stale: " .. tostring(err))
	end)
end)
SelfTest.case("tools: value codec", function()
	local v = Tools.encodeValue(Vector3.new(1, 2, 3))
	assert(v.x == 1 and v.z == 3, "vector3")
	local c = Tools.encodeValue(Color3.fromRGB(255, 0, 128))
	assert(c.r == 255 and c.b == 128, "color3")
	assert(Tools.encodeValue(Enum.Material.Neon) == "Neon", "enum")
	assert(Tools.decodeValue('{"x":1,"y":2,"z":3}', "Vector3") == Vector3.new(1, 2, 3), "decode v3")
	assert(Tools.decodeValue('"Neon"', "Material") == Enum.Material.Neon, "decode enum")
	assert(Tools.decodeValue("true", "boolean") == true, "decode bool")
	local _, err = Tools.decodeValue('"Nope"', "Material")
	assert(err, "bad enum rejected")
end)
SelfTest.case("tools: index caps and labels", function()
	withScratch(function(f)
		for i = 1, INDEX_MAX_ENTRIES + 5 do
			local p = Instance.new("Folder"); p.Name = "F" .. i; p.Parent = f
		end
		local r = Tools.read.index({ path = "ServerStorage.RSP_TestScratch", depth = 1 })
		assert(r.ok and r.truncated == 5, "truncated count " .. tostring(r.truncated))
		assert(select(2, r.text:gsub("\n", "")) >= INDEX_MAX_ENTRIES - 1, "line count")
	end)
end)
SelfTest.case("tools: search plain vs pattern", function()
	withScratch(function(f)
		local s = Instance.new("Script"); s.Name = "S"; s.Source = "local Shop = 1\nlocal x = Shop + 1"; s.Parent = f
		local r = Tools.read.search({ text = "shop", root = "ServerStorage.RSP_TestScratch", pattern = false })
		assert(r.ok and #r.hits == 2, "plain ci hits " .. tostring(r.ok and #r.hits))
		local bad = Tools.read.search({ text = "%", root = "ServerStorage.RSP_TestScratch", pattern = true })
		assert(bad.ok == false, "malformed pattern is a tool error, not a throw")
	end)
end)
```
Reload with `DEV = true`. Expected: four FAIL lines naming `Tools`.

- [ ] **Step 2: Implement refs, resolution, source reads, codec, whitelist**

```lua
local Tools = { read = {}, write = {} }
local Refs = {} -- "#rN" -> Instance
local RefOf = setmetatable({}, { __mode = "k" }) -- Instance -> "#rN"
local refCounter = 0
do
	function Tools.clearRefs()
		Refs = {}
		RefOf = setmetatable({}, { __mode = "k" })
		refCounter = 0
	end

	function Tools.ref(inst)
		local r = RefOf[inst]
		if r then return r end
		refCounter += 1
		r = "#r" .. refCounter
		Refs[r] = inst
		RefOf[inst] = r
		return r
	end

	function Tools.resolve(target)
		if type(target) ~= "string" or #target == 0 then
			return nil, "empty target"
		end
		if target:sub(1, 2) == "#r" then
			local inst = Refs[target]
			if inst and inst:IsDescendantOf(game) then
				return inst
			end
			return nil, "ref " .. target .. " is stale and no path was given"
		end
		local inst = walkPath(target)
		if inst then return inst end
		return nil, "path did not resolve: " .. target
	end

	function Tools.readSource(script)
		local ok, src = pcall(function() return ScriptEditorService:GetEditorSource(script) end)
		if ok and type(src) == "string" then return src end
		return script.Source
	end
	function Tools.hashOf(script)
		return Store.hash(Tools.readSource(script))
	end

	function Tools.encodeValue(v)
		local t = typeof(v)
		if t == "Vector3" then return { x = v.X, y = v.Y, z = v.Z }
		elseif t == "Color3" then return { r = math.floor(v.R * 255 + 0.5), g = math.floor(v.G * 255 + 0.5), b = math.floor(v.B * 255 + 0.5) }
		elseif t == "UDim" then return { s = v.Scale, o = v.Offset }
		elseif t == "UDim2" then return { xs = v.X.Scale, xo = v.X.Offset, ys = v.Y.Scale, yo = v.Y.Offset }
		elseif t == "Vector2" then return { x = v.X, y = v.Y }
		elseif t == "EnumItem" then return v.Name
		elseif t == "Instance" then return v:GetFullName()
		elseif t == "string" or t == "number" or t == "boolean" or t == "nil" then return v
		end
		return { typeof = t, value = tostring(v) } -- read-only fallback; never fails inspect
	end

	-- expected: "string"|"number"|"boolean"|"Vector3"|"Color3"|"UDim"|"UDim2"|"Vector2"|<EnumName>|"Instance"
	function Tools.decodeValue(str, expected)
		local ok, v = pcall(function() return HttpService:JSONDecode(str) end)
		if not ok then return nil, "value is not JSON: " .. tostring(str):sub(1, 60) end
		if expected == "string" or expected == "number" or expected == "boolean" then
			if type(v) ~= expected then return nil, "expected " .. expected end
			return v
		elseif expected == "Vector3" then
			if type(v) ~= "table" then return nil, "expected {x,y,z}" end
			return Vector3.new(tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0)
		elseif expected == "Vector2" then
			return Vector2.new(tonumber(v.x) or 0, tonumber(v.y) or 0)
		elseif expected == "Color3" then
			if type(v) ~= "table" then return nil, "expected {r,g,b} 0-255" end
			return Color3.fromRGB(math.clamp(tonumber(v.r) or 0, 0, 255), math.clamp(tonumber(v.g) or 0, 0, 255), math.clamp(tonumber(v.b) or 0, 0, 255))
		elseif expected == "UDim" then
			return UDim.new(tonumber(v.s) or 0, tonumber(v.o) or 0)
		elseif expected == "UDim2" then
			return UDim2.new(tonumber(v.xs) or 0, tonumber(v.xo) or 0, tonumber(v.ys) or 0, tonumber(v.yo) or 0)
		elseif expected == "Instance" then
			local inst = type(v) == "string" and Tools.resolve(v)
			if not inst then return nil, "instance path did not resolve" end
			return inst
		else -- Enum name
			local e = Enum[expected]
			if not e then return nil, "unknown type " .. expected end
			local okE, item = pcall(function() return e[v] end)
			if not okE or item == nil then return nil, ("%s is not a %s"):format(tostring(v), expected) end
			return item
		end
	end

	-- Spec §5.4. Keyed by class; Tools.propsFor walks IsA so BasePart covers Part/MeshPart/etc.
	local TEXT = { Text = "string", TextColor3 = "Color3", TextSize = "number", Font = "Font", TextScaled = "boolean", TextWrapped = "boolean", RichText = "boolean" }
	WHITELIST = {
		Instance = { Name = "string", Archivable = "boolean" },
		BasePart = { Anchored = "boolean", CanCollide = "boolean", CanTouch = "boolean", CanQuery = "boolean", Transparency = "number", Reflectance = "number", Color = "Color3", Material = "Material", Size = "Vector3", Position = "Vector3", Orientation = "Vector3", CastShadow = "boolean", Massless = "boolean" },
		Model = { PrimaryPart = "Instance" },
		Light = { Brightness = "number", Color = "Color3", Range = "number", Enabled = "boolean", Shadows = "boolean" },
		Lighting = { Ambient = "Color3", OutdoorAmbient = "Color3", Brightness = "number", ClockTime = "number", FogEnd = "number", FogStart = "number", FogColor = "Color3" },
		GuiObject = { Visible = "boolean", Position = "UDim2", Size = "UDim2", AnchorPoint = "Vector2", BackgroundColor3 = "Color3", BackgroundTransparency = "number", ZIndex = "number", LayoutOrder = "number" },
		TextLabel = TEXT, TextButton = TEXT, TextBox = TEXT,
		ScreenGui = { Enabled = "boolean", ResetOnSpawn = "boolean", DisplayOrder = "number" },
		UIListLayout = { FillDirection = "FillDirection", HorizontalAlignment = "HorizontalAlignment", VerticalAlignment = "VerticalAlignment", SortOrder = "SortOrder", Padding = "UDim" },
		UIGridLayout = { FillDirection = "FillDirection", HorizontalAlignment = "HorizontalAlignment", VerticalAlignment = "VerticalAlignment", SortOrder = "SortOrder", CellSize = "UDim2", CellPadding = "UDim2" },
		UICorner = { CornerRadius = "UDim" },
		UIPadding = { PaddingTop = "UDim", PaddingBottom = "UDim", PaddingLeft = "UDim", PaddingRight = "UDim" },
		UIStroke = { Color = "Color3", Thickness = "number", Transparency = "number" },
		ProximityPrompt = { ActionText = "string", ObjectText = "string", HoldDuration = "number", MaxActivationDistance = "number", Enabled = "boolean" },
		ClickDetector = { MaxActivationDistance = "number" },
		Sound = { SoundId = "string", Volume = "number", Looped = "boolean", Playing = "boolean", PlaybackSpeed = "number" },
		StringValue = { Value = "string" }, NumberValue = { Value = "number" }, IntValue = { Value = "number" }, BoolValue = { Value = "boolean" }, ObjectValue = { Value = "Instance" }, Vector3Value = { Value = "Vector3" }, Color3Value = { Value = "Color3" },
		BaseScript = { Enabled = "boolean" },
	}
	function Tools.propsFor(inst)
		local out = {}
		for class, props in pairs(WHITELIST) do
			if inst:IsA(class) then
				for k, v in pairs(props) do out[k] = v end
			end
		end
		return out
	end
end
```
Declare `local WHITELIST` next to `local Tools` (it is assigned inside the `do`). The `TEXT` classes share one table on purpose.

- [ ] **Step 3: Implement the read tools**

```lua
do
	local SKIP_INDEX = { CoreGui = true, Chat = true, TextChatService = true, Terrain = true, Camera = true }

	local function scriptLines(inst)
		local src = Tools.readSource(inst)
		local _, n = src:gsub("\n", "")
		return n + 1, Store.hash(src)
	end

	function Tools.read.index(args)
		local root = (args.path == nil or args.path == "game") and game or Tools.resolve(args.path)
		if not root then return { ok = false, error = "path did not resolve: " .. tostring(args.path) } end
		local depth = math.clamp(tonumber(args.depth) or 2, 1, 3)
		local manifest = Store.readManifest()
		local lines, count, truncated = {}, 0, 0
		local function walk(inst, d, indent)
			for _, ch in ipairs(inst:GetChildren()) do
				if not SKIP_INDEX[ch.ClassName] and not SKIP_INDEX[ch.Name] then
					if count >= INDEX_MAX_ENTRIES then
						truncated += 1
					else
						count += 1
						local extra = ""
						if ch:IsA("LuaSourceContainer") then
							local n, h = scriptLines(ch)
							local stored = manifest[ch:GetFullName()]
							extra = (" | %d lines"):format(n) .. (stored and stored ~= h and " | edited-outside" or "")
						end
						local label = (ch.Parent == ServerStorage and ch.Name == "RoScriptPro") and " [RoScript Pro store]" or ""
						table.insert(lines, ("%s%s | %s | %d children%s%s | %s"):format(indent, ch.Name, ch.ClassName, #ch:GetChildren(), extra, label, Tools.ref(ch)))
						if d > 1 and label == "" then walk(ch, d - 1, indent .. "  ") end
					end
				end
			end
		end
		walk(root, depth, "")
		local text = table.concat(lines, "\n")
		if truncated > 0 then text ..= ("\n…%d more, narrow the path"):format(truncated) end
		return { ok = true, text = text, count = count, truncated = truncated }
	end

	function Tools.read.inspect(args)
		local inst, err = Tools.resolve(args.target)
		if not inst then return { ok = false, error = err } end
		local props = {}
		for name in pairs(Tools.propsFor(inst)) do
			local okP, v = pcall(function() return inst[name] end)
			if okP then props[name] = Tools.encodeValue(v) end
		end
		props.ClassName = inst.ClassName
		props.Parent = inst.Parent and inst.Parent:GetFullName() or nil
		local attrs = {}
		for k, v in pairs(inst:GetAttributes()) do attrs[k] = Tools.encodeValue(v) end
		local children = {}
		for i, ch in ipairs(inst:GetChildren()) do
			if i > 20 then table.insert(children, ("…%d more"):format(#inst:GetChildren() - 20)); break end
			table.insert(children, ch.Name .. " (" .. ch.ClassName .. ") " .. Tools.ref(ch))
		end
		return { ok = true, path = inst:GetFullName(), ref = Tools.ref(inst), props = props, attributes = attrs, tags = inst:GetTags(), children = children }
	end

	function Tools.read.read_script(args)
		local inst, err = Tools.resolve(args.target)
		if not inst then return { ok = false, error = err } end
		if not inst:IsA("LuaSourceContainer") then return { ok = false, error = "not a script: " .. inst.ClassName } end
		local src = Tools.readSource(inst)
		local all = src:split("\n")
		local from = math.max(1, tonumber(args.fromLine) or 1)
		local to = math.min(#all, tonumber(args.toLine) or #all)
		local out, chars = {}, 0
		for i = from, to do
			local line = ("%d\t%s"):format(i, all[i])
			chars += #line + 1
			if chars > READ_SCRIPT_MAX then
				table.insert(out, ("… cut at line %d; call again with fromLine=%d"):format(i, i))
				break
			end
			table.insert(out, line)
		end
		return { ok = true, path = inst:GetFullName(), ref = Tools.ref(inst), totalLines = #all, hash = Store.hash(src), text = table.concat(out, "\n") }
	end

	function Tools.read.search(args)
		local root = (args.root == nil or args.root == "game") and game or Tools.resolve(args.root)
		if not root then return { ok = false, error = "root did not resolve" } end
		local needle = tostring(args.text or "")
		if #needle == 0 then return { ok = false, error = "empty search text" } end
		local usePattern = args.pattern == true
		local hits = {}
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("LuaSourceContainer") and not inst:IsDescendantOf(Store.root() or inst) then
				local path = inst:GetFullName()
				for i, line in ipairs(Tools.readSource(inst):split("\n")) do
					local found
					if usePattern then
						local okF, res = pcall(string.find, line, needle)
						if not okF then return { ok = false, error = "malformed Luau pattern: " .. tostring(res) } end
						found = res ~= nil
					else
						found = line:lower():find(needle:lower(), 1, true) ~= nil
					end
					if found then
						table.insert(hits, ("%s:%d: %s"):format(path, i, utf8Trim(line, 160)))
						if #hits >= SEARCH_MAX_HITS then
							return { ok = true, hits = hits, truncated = true }
						end
					end
				end
			end
		end
		return { ok = true, hits = hits, truncated = false }
	end

	function Tools.read.read_output(args)
		local count = math.clamp(tonumber(args.count) or 40, 1, 200)
		local hist = LogService:GetLogHistory()
		local out, chars = {}, 0
		for i = #hist, 1, -1 do
			local e = hist[i]
			if e.messageType == Enum.MessageType.MessageError or e.messageType == Enum.MessageType.MessageWarning then
				local line = ("[%s] %s"):format(e.messageType.Name:gsub("Message", ""), utf8Trim(tostring(e.message), 200))
				chars += #line
				if chars > OUTPUT_MAX_CHARS or #out >= count then break end
				table.insert(out, line)
			end
		end
		return { ok = true, lines = out, ringSize = #hist }
	end

	function Tools.read.read_memory(args)
		local facts, notes = Store.readMemory()
		return { ok = true, facts = facts, notes = notes }
	end
	function Tools.read.list_plans(args)
		local page, total = Store.listPlans(tonumber(args.offset) or 0)
		return { ok = true, plans = page, total = total }
	end
	function Tools.read.read_plan(args)
		local rec, err = Store.readPlan(tostring(args.id or ""))
		if not rec then return { ok = false, error = err } end
		return { ok = true, record = rec }
	end
end
```

- [ ] **Step 4: Reload and verify green**

Expected: all `tools:` cases PASS along with the earlier ones. Studio check: in the command bar, `print(require)` is not needed; instead temporarily set `DEV = true` and add a one-off case that prints `Tools.read.index({ path = "game", depth = 1 }).text` to eyeball the top-level services list, then remove it.

- [ ] **Step 5: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: TOOLS read set (refs, source reads, whitelist codec, index/inspect/read_script/search/read_output)"
```

---

### Task 4: PROVIDER — tool-call transport, Goal queue, classifier order

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `5. PROVIDER`: `callProvider`, `chatOnce`, `buildQueue`, `classifyFailure`, `PAT_TOOLARGE`.

**Interfaces:**
- Consumes: Task 1 flags (`MODEL_CHAIN[i].tools`, `PROV[p].strictTools`), `GOAL_MAXTOK`, `GOAL_TEMPERATURE`, `PAT_BADTOOLCALL`.
- Produces:
  - `callProvider(entry, messages, opts?)` where `opts = { tools: table?, maxTokens: number?, temperature: number?, minimal: boolean? }`; returns `{ text: string?, toolCalls: table?, reasoning: string?, usage: table?, truncated: boolean, entry }` or the same 5-tuple failure as v1.
  - `buildQueue(goalOnly: boolean?)`
  - `chatOnce(messages, state, statusFn, opts?)` with `opts.goal = true` (filters the queue), `opts.estTokens` (skips Groq when above `GROQ_REQ_MAX`), plus the `callProvider` opts passed through; `state.lastCode` set on failure.
  - `classifyFailure` returns a new action `"retry-same"` for `PAT_BADTOOLCALL`.
- Chat mode behaviour is unchanged: it never passes `opts`.

- [ ] **Step 1: Write the failing self-tests**

The classifier is pure given synthetic inputs:
```lua
SelfTest.case("provider: 413 classifies as too-large before rate-limit", function()
	local state = { failedModels = {}, failedProviders = {} }
	local entry = { p = "groq", m = "openai/gpt-oss-120b", key = "k", idx = 1 }
	local reason, action = classifyFailure(entry, 413, '{"error":{"message":"Request too large for model ... on tokens per minute (TPM): Limit 8000, Requested 12000","code":"rate_limit_exceeded"}}', {}, nil, state)
	assert(action == "next" and state.failedProviders.groq == true, "413 must mark provider too-large, got " .. tostring(reason))
	assert(Cooling["groq:1"] == nil, "413 must not cool the key")
end)
SelfTest.case("provider: tool_use_failed asks for a same-entry retry", function()
	local state = { failedModels = {}, failedProviders = {} }
	local entry = { p = "groq", m = "openai/gpt-oss-120b", key = "k", idx = 2 }
	local _, action = classifyFailure(entry, 400, '{"error":{"code":"tool_use_failed","failed_generation":"{bad json"}}', {}, nil, state)
	assert(action == "retry-same", "got " .. tostring(action))
end)
SelfTest.case("provider: goal queue filters tool-less entries", function()
	local q = buildQueue(true)
	for _, e in ipairs(q) do
		local link
		for _, l in ipairs(MODEL_CHAIN) do if l.p == e.p and l.m == e.m then link = l end end
		assert(link and link.tools == true, "tool-less entry in goal queue: " .. e.m)
	end
end)
```
Reload with `DEV = true`. Expected: first two FAIL (413 currently classifies as rate limit; 400 tool_use_failed returns "next"), third FAIL (`buildQueue` ignores its argument, so tool-less entries appear when keys exist).

- [ ] **Step 2: Reorder and extend `classifyFailure`**

Replace the body after the `pcallErr` block with:
```lua
	-- Too-large FIRST, by status code: Groq's 413 body also says rate_limit_exceeded (spec §6.5, A3).
	if code == 413 or (code == 400 and matchAny(bodyText, PAT_TOOLARGE)) then
		state.failedProviders[entry.p] = true
		state.lastCode = code
		return pname .. ": request too large", "next"
	end
	if code == 400 and matchAny(bodyText, PAT_BADTOOLCALL) then
		state.lastCode = code
		return pname .. ": model produced a malformed tool call, retrying", "retry-same"
	end
	if code == 429 or matchAny(bodyText, PAT_RATELIMIT) then
		Cooling[id] = os.clock() + (retryAfterSeconds(headers, bodyText) or COOLDOWN_DEFAULT)
		return pname .. " key #" .. entry.idx .. " cooling", "next"
	end
	if code == 401 or code == 403 or matchAny(bodyText, PAT_AUTH) then
		Bad[id] = true
		return pname .. " key #" .. entry.idx .. " invalid", "next"
	end
	if code == 400 and bodyText:lower():find("reasoning_effort") and not EffortStripped[entry.p] then
		EffortStripped[entry.p] = true
		return pname .. " rejected reasoning_effort — retrying without it", "retry-stripped"
	end
	if code == 404 or matchAny(bodyText, PAT_MODELDEAD) then
		state.failedModels[entry.p .. ":" .. entry.m] = true
		return pname .. "/" .. entry.m .. " unavailable", "next"
	end
	return pname .. " HTTP " .. tostring(code), "next"
```
And extend the pattern list: `local PAT_TOOLARGE = { "request too large", "body is too large", "context_length", "maximum context", "too many tokens", "reduce the length" }`.

- [ ] **Step 3: `buildQueue(goalOnly)` and `callProvider` opts**

```lua
local function buildQueue(goalOnly)
	local queue = {}
	local keysByProvider = {}
	for _, p in ipairs(PROV_ORDER) do
		keysByProvider[p] = KeyStore.load(p)
	end
	for _, link in ipairs(MODEL_CHAIN) do
		if not goalOnly or link.tools == true then
			for idx, key in ipairs(keysByProvider[link.p] or {}) do
				local entry = { p = link.p, m = link.m, key = key, idx = idx }
				if isAvailable(entry) then
					table.insert(queue, entry)
				end
			end
		end
	end
	return queue
end
```
In `callProvider(entry, messages, opts)`:
```lua
	opts = opts or {}
	local body = {
		model = entry.m,
		messages = messages,
		max_tokens = opts.maxTokens or MAXTOK[entry.p],
		temperature = opts.temperature or 0.5,
	}
	if opts.tools then
		local tools = opts.tools
		if PROV[entry.p].strictTools then
			tools = table.clone(tools)
			for i, t in ipairs(tools) do
				local f = table.clone(t["function"]); f.strict = true
				tools[i] = { type = "function", ["function"] = f }
			end
		end
		body.tools = tools
		if entry.p == "openrouter" then
			body.provider = { require_parameters = true } -- minimal body: nothing else optional below
		elseif not (entry.m:find("gpt%-oss") and entry.p == "groq") then
			body.parallel_tool_calls = true -- gpt-oss on Groq has no parallel tool use (A1)
		end
	end
	if entry.m:find("gpt%-oss") and not EffortStripped[entry.p] and not (opts.tools and entry.p == "openrouter") then
		body.reasoning_effort = "low"
	end
```
After decoding, replace the `choice.message` handling:
```lua
	local msg = choice.message
	local text = msg.content
	local calls = msg.tool_calls
	if (type(text) ~= "string" or text:gsub("%s", "") == "") and not (type(calls) == "table" and #calls > 0) then
		return nil, resp.StatusCode, "empty content", resp.Headers, nil
	end
	return {
		text = type(text) == "string" and text or nil,
		toolCalls = (type(calls) == "table" and #calls > 0) and calls or nil,
		reasoning = type(msg.reasoning) == "string" and msg.reasoning or nil,
		usage = decoded.usage,
		truncated = (choice.finish_reason == "length"),
		entry = entry,
	}
```
Every v1 caller of `result.text` still works because Chat never gets `toolCalls` (no `tools` in its body).

- [ ] **Step 4: `chatOnce` opts, Groq size skip, retry-same**

Signature `local function chatOnce(messages, state, statusFn, opts)`; `opts = opts or {}`; `local queue = buildQueue(opts.goal == true)`. Inside the loop, extend `skip`:
```lua
		local skip = state.failedModels[entry.p .. ":" .. entry.m]
			or state.failedProviders[entry.p]
			or not isAvailable(entry)
			or (opts.estTokens and entry.p == "groq" and opts.estTokens > GROQ_REQ_MAX)
```
Pass `opts` to every `callProvider(entry, messages, opts)` call in the function. Add the new action branch next to `retry-stripped`:
```lua
			elseif action == "retry-same" and not state.retriedSame then
				state.retriedSame = true
				local retryOpts = table.clone(opts); retryOpts.temperature = 0
				local r2, c2, b2, h2, e2 = callProvider(entry, messages, retryOpts)
				if r2 then return r2 end
				lastReason = classifyFailure(entry, c2, b2, h2, e2, state)
```
When the queue is empty **because** every Groq entry was size-skipped and nothing else exists, return the specific message from spec §6.4: build `queue` first, then if `#queue > 0` but every entry was skipped by the size rule, return `nil, ("Request is ~%d tokens; Groq's 8K limit excludes it and no Cerebras or OpenRouter key is available. Add one in Settings or narrow the goal."):format(opts.estTokens)`. Track this with a local `sizeSkipped` counter inside the loop.

- [ ] **Step 5: Reload, verify green, regression-check Chat**

Expected: the three `provider:` cases PASS. Then send one Chat message and confirm a normal answer and status `Answered by …`. Send a second while the first is in flight and press Stop: unchanged behaviour.

- [ ] **Step 6: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "provider: tool-call transport, goal queue filter, 413-first classifier, malformed-tool-call retry"
```

---

### Task 5: AGENT core — schemas, sizing, compaction, waits, batch runner

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `10. AGENT` (first half).

**Interfaces:**
- Consumes: `chatOnce(messages, state, statusFn, opts)`, `Tools.read`/`Tools.write` dispatch tables, `Executor.runWriteBatch` (Task 7; until then AGENT only runs read batches), `GoalUI`, `Goal`, `Store`, constants.
- Produces (`local Agent = {}` plus locals):
  - `Schemas.tool(name) -> table` (one OpenAI tool object), `Schemas.forPhase(phase: string) -> {table}` where phase ∈ `PLANNING|REVISING|ACTING|REPAIRING|RECORDING`
  - `estimateTokens(messages, tools, lastUsage) -> number`
  - `compactConvo(convo: {messages}) -> boolean` (true if anything was elided)
  - `requestWithWaits(convo, phaseState, tools) -> result?, err?` — wraps `chatOnce` with size routing, compaction-on-too-large, cooldown waits, Cerebras pacing, request counters, `models` bookkeeping, `gen` checks
  - `runToolBatch(calls, phaseState) -> results: {{id, content}}, control: {name, args}?` — dispatches read tools and, in write phases, hands write calls to `Executor.runWriteBatch`; enforces the batch budget rule and the consecutive-error counter
  - `phaseState` shape: `{ phase, budget = { calls, tokens }, used = { calls = 0, tokens = 0 }, consecutiveErrors = 0, turns = 0, nudged = false, myGen, step? }`
  - `Agent.checkGen(myGen) -> boolean` (`myGen == Goal.gen and not unloaded`)

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("agent: schemas obey strict rules", function()
	local json = HttpService:JSONEncode(Schemas.forPhase("PLANNING"))
	assert(not json:find('"properties":[]', 1, true), "no empty properties arrays")
	assert(not json:find("minItems", 1, true) and not json:find("maxLength", 1, true), "no bounds in schema")
	local rs = Schemas.tool("read_script")
	local p = rs["function"].parameters
	assert(p.additionalProperties == false, "additionalProperties false")
	assert(#p.required == 3, "all props required, got " .. #p.required)
	assert(type(p.properties.fromLine.type) == "table" and p.properties.fromLine.type[2] == "null", "optional is nullable")
	local names = {}
	for _, t in ipairs(Schemas.forPhase("ACTING")) do names[t["function"].name] = true end
	assert(names.write_script and names.finish_step and not names.submit_plan, "acting set")
	local rec = Schemas.forPhase("RECORDING")
	assert(#rec == 1 and rec[1]["function"].name == "write_memory", "recording set")
end)
SelfTest.case("agent: estimate and compaction", function()
	local convo = { messages = { { role = "system", content = string.rep("s", 4000) }, { role = "user", content = "u" } } }
	for i = 1, 6 do
		table.insert(convo.messages, { role = "assistant", content = "", tool_calls = { { id = "c" .. i, type = "function", ["function"] = { name = "index", arguments = "{}" } } } })
		table.insert(convo.messages, { role = "tool", tool_call_id = "c" .. i, content = string.rep("t", 20000) })
	end
	local before = estimateTokens(convo.messages, {}, nil)
	assert(before > 30000, "big convo estimate " .. before)
	assert(compactConvo(convo) == true, "compacted")
	assert(convo.messages[4].content:find("elided", 1, true), "oldest tool result elided first")
	assert(estimateTokens(convo.messages, {}, nil) <= BIG_REQ_MAX, "under cap after compaction")
	assert(estimateTokens({ { role = "user", content = "x" } }, {}, { prompt_tokens = 1000, completion_tokens = 50 }) >= 1050, "usage-based estimate")
end)
SelfTest.case("agent: batch budget rule", function()
	local ps = { phase = "PLANNING", budget = { calls = 2, tokens = 1e9 }, used = { calls = 1, tokens = 0 }, consecutiveErrors = 0, turns = 0, myGen = Goal.gen }
	local calls = {
		{ id = "a", ["function"] = { name = "read_memory", arguments = '{"reason":"x"}' } },
		{ id = "b", ["function"] = { name = "read_memory", arguments = '{"reason":"y"}' } },
	}
	local results, control = runToolBatch(calls, ps)
	assert(#results == 2 and results[1].content:find("budget exhausted", 1, true), "over-budget batch executes nothing")
	assert(ps.exhausted == true, "phase flagged exhausted")
end)
```
Reload with `DEV = true`. Expected: three FAIL lines naming `Schemas`, `estimateTokens`, `runToolBatch`.

- [ ] **Step 2: Implement schemas**

```lua
local Schemas = {}
do
	-- t(typeName, nullable) builds a JSON-schema type; every property is required (§6.1).
	local function t(kind, nullable)
		if nullable then return { type = { kind, "null" } } end
		return { type = kind }
	end
	local STR, INT, BOOL = t("string"), t("integer"), t("boolean")
	local function arr(items) return { type = "array", items = items } end
	local function obj(props, order)
		return { type = "object", properties = props, required = order, additionalProperties = false }
	end
	local PAIR = obj({ name = STR, value = STR }, { "name", "value" })
	local STEP = obj({
		title = STR, action = { type = "string", enum = { "edit", "create", "move", "trash", "props", "mixed" } },
		targets = arr(STR), detail = STR, risk = { type = "string", enum = { "low", "medium", "high" } },
	}, { "title", "action", "targets", "detail", "risk" })

	local DEFS = {
		index = { "List children of a path: name | class | children | lines | flags | #ref. depth 1-3. 200 entries max, narrow the path if truncated.", obj({ path = t("string", true), depth = t("integer", true) }, { "path", "depth" }) },
		inspect = { "Whitelisted properties, attributes, tags and children of one instance (path or #ref).", obj({ target = STR }, { "target" }) },
		read_script = { "Numbered source of a script, optionally a line range. 8000 chars per call; page with fromLine.", obj({ target = STR, fromLine = t("integer", true), toLine = t("integer", true) }, { "target", "fromLine", "toLine" }) },
		search = { "Find text in scripts under root. Plain case-insensitive substring unless pattern=true (Luau pattern).", obj({ text = STR, root = t("string", true), pattern = t("boolean", true) }, { "text", "root", "pattern" }) },
		read_output = { "Newest Output errors and warnings, with script paths when present.", obj({ count = t("integer", true) }, { "count" }) },
		read_memory = { "Project memory: plugin-generated Facts and model-written Notes.", obj({ reason = STR }, { "reason" }) },
		list_plans = { "Past plan records, 10 per page.", obj({ offset = t("integer", true) }, { "offset" }) },
		read_plan = { "One plan record, including what its steps actually wrote.", obj({ id = STR }, { "id" }) },
		replace_lines = { "Replace inclusive line range fromLine..toLine with newText. expectHash must equal the hash read_script returned.", obj({ target = STR, fromLine = INT, toLine = INT, expectHash = STR, newText = STR }, { "target", "fromLine", "toLine", "expectHash", "newText" }) },
		edit_script = { "Plain-text find/replace in a script. Fails if find is missing or ambiguous (all=false).", obj({ target = STR, find = STR, replace = STR, all = BOOL }, { "target", "find", "replace", "all" }) },
		write_script = { "Replace a script's whole source. Prefer replace_lines/edit_script for existing scripts.", obj({ target = STR, source = STR }, { "target", "source" }) },
		create = { "Create an instance. props: array of {name, value} where value is JSON text; attributes use @name.", obj({ class = STR, parent = STR, name = STR, props = { type = { "array", "null" }, items = PAIR }, source = t("string", true) }, { "class", "parent", "name", "props", "source" }) },
		set_props = { "Set whitelisted properties/attributes on 1-50 targets. props: array of {name, value(JSON text)}; @name = attribute.", obj({ targets = arr(STR), props = arr(PAIR) }, { "targets", "props" }) },
		move = { "Reparent 1-50 targets.", obj({ targets = arr(STR), newParent = STR }, { "targets", "newParent" }) },
		trash = { "Move 1-50 targets to the RoScript Pro Trash (never destroys).", obj({ targets = arr(STR) }, { "targets" }) },
		submit_plan = { "Submit the plan. At most 10 steps.", obj({ title = STR, summary = STR, verify_hint = STR, steps = arr(STEP) }, { "title", "summary", "verify_hint", "steps" }) },
		finish_step = { "Finish the current step with a one-paragraph outcome.", obj({ outcome = STR }, { "outcome" }) },
		write_memory = { "Rewrite the Notes block of project memory and give this plan's summary.", obj({ notes = STR, plan_summary = STR }, { "notes", "plan_summary" }) },
	}
	local READ = { "index", "inspect", "read_script", "search", "read_output", "read_memory", "list_plans", "read_plan" }
	local WRITE = { "replace_lines", "edit_script", "write_script", "create", "set_props", "move", "trash" }
	local PHASES = {
		PLANNING = { READ, { "submit_plan" } }, REVISING = { READ, { "submit_plan" } },
		ACTING = { READ, WRITE, { "finish_step" } }, REPAIRING = { READ, WRITE, { "finish_step" } },
		RECORDING = { { "write_memory" } },
	}
	function Schemas.tool(name)
		local d = assert(DEFS[name], "no schema for " .. name)
		return { type = "function", ["function"] = { name = name, description = d[1], parameters = d[2] } }
	end
	function Schemas.forPhase(phase)
		local out = {}
		for _, group in ipairs(PHASES[phase] or {}) do
			for _, n in ipairs(group) do table.insert(out, Schemas.tool(n)) end
		end
		return out
	end
	function Schemas.allowed(phase)
		local set = {}
		for _, t in ipairs(Schemas.forPhase(phase)) do set[t["function"].name] = true end
		return set
	end
end
```

- [ ] **Step 3: Implement sizing, compaction, the request wrapper**

```lua
local function estimateTokens(messages, tools, lastUsage)
	if lastUsage and lastUsage.prompt_tokens then
		-- usage-based: what the provider counted last time plus what we appended since (escaped Luau ≈ 3 chars/token)
		local added = 0
		for i = #messages, 1, -1 do
			local m = messages[i]
			if m.role == "tool" or (m.role == "user" and i > 1) then added += #(m.content or "") else break end
		end
		return lastUsage.prompt_tokens + (lastUsage.completion_tokens or 0) + math.ceil(added / 3)
	end
	local ok, json = pcall(function() return HttpService:JSONEncode({ messages = messages, tools = tools }) end)
	return ok and math.ceil(#json / 4) or 1e9
end

-- Replace the oldest tool results until under BIG_REQ_MAX. Returns true if anything changed.
local function compactConvo(convo)
	local changed = false
	local ELIDED = "[result elided; call the tool again if needed]"
	while estimateTokens(convo.messages, convo.tools, nil) > BIG_REQ_MAX do
		local victim
		for _, m in ipairs(convo.messages) do
			if m.role == "tool" and m.content ~= ELIDED then victim = m; break end
		end
		if not victim then break end
		victim.content = ELIDED
		changed = true
	end
	return changed
end

function Agent.checkGen(myGen)
	return myGen == Goal.gen and not unloaded
end

local lastCerebrasAt = {} -- key idx -> os.clock()

-- One model turn with all the free-tier survival rules (§6.4, §6.7).
local function requestWithWaits(convo, ps, tools)
	local waits = 0
	while true do
		if not Agent.checkGen(ps.myGen) then return nil, "stopped" end
		local est = estimateTokens(convo.messages, tools, convo.lastUsage)
		if est > BIG_REQ_MAX then
			compactConvo(convo)
			est = estimateTokens(convo.messages, tools, nil)
			if est > BIG_REQ_MAX then return nil, "context too large for the free tiers" end
		end
		if ps.used.tokens + est > ps.budget.tokens then
			ps.exhausted = true
			return nil, "phase token ceiling reached"
		end
		-- Cerebras pacing: 5 RPM, no retry-after published.
		for idx, at in pairs(lastCerebrasAt) do
			local gap = CEREBRAS_MIN_GAP - (os.clock() - at)
			if gap > 0 and gap < CEREBRAS_MIN_GAP then
				GoalUI.setPhase(ps.phase, ("pacing Cerebras key #%d, %ds"):format(idx, math.ceil(gap)))
				task.wait(gap)
				if not Agent.checkGen(ps.myGen) then return nil, "stopped" end
			end
		end
		local state = { failedModels = {}, failedProviders = {} }
		local opts = { goal = true, tools = tools, temperature = GOAL_TEMPERATURE, estTokens = est, maxTokens = nil }
		local result, err = chatOnce(convo.messages, state, function(text) GoalUI.setPhase(ps.phase, text) end, opts)
		if not Agent.checkGen(ps.myGen) then return nil, "stopped" end
		if result then
			ps.used.tokens += (result.usage and result.usage.total_tokens) or est
			convo.lastUsage = result.usage
			Goal.requests[result.entry.p] = (Goal.requests[result.entry.p] or 0) + 1
			if result.entry.p == "cerebras" then lastCerebrasAt[result.entry.idx] = os.clock() end
			local tag = result.entry.p .. "/" .. result.entry.m
			if not table.find(Goal.models, tag) then table.insert(Goal.models, tag) end
			return result
		end
		-- too large somewhere: compact once and retry the remaining queue
		if state.lastCode == 413 and not convo.compactedOnce then
			convo.compactedOnce = true
			if compactConvo(convo) then continue end
		end
		-- cooldown wait: only when something is merely cooling
		local soonest
		for id, deadline in pairs(Cooling) do
			local p = id:match("^(%w+):")
			if not Bad[id] and not state.failedProviders[p] then
				local dt = deadline - os.clock()
				if dt > 0 and (not soonest or dt < soonest) then soonest = dt end
			end
		end
		if soonest and soonest <= GOAL_WAIT_MAX and waits < GOAL_WAITS_PER_REQUEST then
			waits += 1
			GoalUI.setPhase(ps.phase, ("waiting %ds for a key to cool"):format(math.ceil(soonest)))
			task.wait(soonest + 1)
			continue
		end
		return nil, err
	end
end
```
`maxTokens = nil` lets `callProvider` fall back to `MAXTOK`; change that line to pick `GOAL_MAXTOK[entry.p]` inside `callProvider` when `opts.goal` is true: add `if opts.goal then body.max_tokens = GOAL_MAXTOK[entry.p] end` after the `body` table in `callProvider` (Task 4 file).

- [ ] **Step 4: Implement the batch runner**

```lua
local CONTROL = { submit_plan = true, finish_step = true, write_memory = true }
local WRITE_TOOLS = { replace_lines = true, edit_script = true, write_script = true, create = true, set_props = true, move = true, trash = true }

local function decodeArgs(call)
	local ok, args = pcall(function() return HttpService:JSONDecode(call["function"].arguments or "{}") end)
	if not ok or type(args) ~= "table" then return nil, "arguments are not a JSON object" end
	return args
end

-- Returns results (one per call, in order) and the control call {name, args} if the batch committed.
local function runToolBatch(calls, ps)
	local results = {}
	local allowed = Schemas.allowed(ps.phase)
	local nonControl = 0
	for _, c in ipairs(calls) do if not CONTROL[c["function"].name] then nonControl += 1 end end
	if ps.used.calls + nonControl > ps.budget.calls then
		ps.exhausted = true
		for _, c in ipairs(calls) do
			table.insert(results, { id = c.id, content = HttpService:JSONEncode({ ok = false, error = "call budget exhausted", attributable = false }) })
		end
		return results, nil
	end
	local writes, control = {}, nil
	local anyAttributableError, anyOk = false, false
	local pending = {} -- index -> result table (writes are filled by the executor)
	for i, c in ipairs(calls) do
		local name = c["function"].name
		local args, aerr = decodeArgs(c)
		if not allowed[name] then
			local names = {}
			for n in pairs(allowed) do table.insert(names, n) end
			table.sort(names)
			pending[i] = { ok = false, error = ("no tool named %s in this phase; available: %s"):format(name, table.concat(names, ", ")) }
		elseif not args then
			pending[i] = { ok = false, error = aerr }
		elseif CONTROL[name] then
			control = { name = name, args = args, index = i }
		elseif WRITE_TOOLS[name] then
			table.insert(writes, { index = i, name = name, args = args })
		else
			ps.used.calls += 1
			local okR, r = pcall(Tools.read[name], args)
			pending[i] = okR and r or { ok = false, error = "tool crashed: " .. tostring(r) }
		end
	end
	local committed = true
	if #writes > 0 then
		ps.used.calls += #writes
		local wres, wcommitted = Executor.runWriteBatch(writes, ps)
		committed = wcommitted
		for _, w in ipairs(writes) do pending[w.index] = wres[w.index] end
	end
	if control then
		if committed then
			pending[control.index] = { ok = true }
		else
			pending[control.index] = { ok = false, error = control.name .. " ignored: batch did not commit", attributable = false }
			control = nil
		end
	end
	for i, c in ipairs(calls) do
		local r = pending[i] or { ok = false, error = "no result" }
		if r.ok then anyOk = true elseif r.attributable ~= false then anyAttributableError = true end
		results[i] = { id = c.id, content = HttpService:JSONEncode(r) }
	end
	if anyAttributableError and not anyOk then ps.consecutiveErrors += 1 else ps.consecutiveErrors = 0 end
	return results, control
end
```
Until Task 7 lands, add a stub directly above so the file loads: `local Executor = { runWriteBatch = function(writes, ps) local r = {}; for _, w in ipairs(writes) do r[w.index] = { ok = false, error = "write tools not built yet", attributable = false } end; return r, false end }`. Task 7 replaces it.

- [ ] **Step 5: Reload and verify green**

Expected: the three `agent:` cases PASS. The estimate case also proves compaction elides the **oldest** tool result first.

- [ ] **Step 6: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: AGENT core (strict schemas, token estimate, compaction, cooldown waits, batch runner)"
```

---

### Task 6: PLANNING phase + Goal view part 1 (toggle, goal box, chips, plan card)

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` sections `10. AGENT` (PLANNING, Revise, Cancel), `11. GOAL UI` (view toggle, goal view, plan card, prompt modal), `12. BOOTSTRAP` (toggle wiring, unload cleanup).

**Interfaces:**
- Consumes: Task 5 (`Schemas`, `requestWithWaits`, `runToolBatch`), `Store`, `Tools.read`, v1 `buildSelectionSummary`, `StudioService.ActiveScript`, `mk`, `C`, `openModalPanel`, `closeModal`, `escapeRich`, `chunkText`.
- Produces:
  - `SYS_GOAL: string` (byte-stable system message), `buildGoalUserBlock(phaseInstruction: string) -> string`
  - `Agent.plan(goalText: string)`, `Agent.revise(note: string)`, `Agent.cancel()`, `Agent.stop()` (PLANNING-only behaviour here; ACTING semantics in Task 8)
  - `validatePlan(obj) -> plan?, err?` (plugin-enforced limits, §7.2)
  - `GoalUI.setPhase`, `GoalUI.log`, `GoalUI.showCard("plan", plan)`, `GoalUI.prompt` (modal with Allow/Skip/Stop), `GoalUI.setBusy`; `Goal view` frames; `setGoalMode(on: boolean)`

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("agent: validatePlan enforces limits", function()
	local steps = {}
	for i = 1, MAX_STEPS + 1 do steps[i] = { title = "s" .. i, action = "edit", targets = { "Workspace.X" }, detail = "d", risk = "low" } end
	local _, err = validatePlan({ title = "t", summary = "s", verify_hint = "v", steps = steps })
	assert(err and err:find("10", 1, true), "too many steps rejected: " .. tostring(err))
	local plan = assert(validatePlan({ title = string.rep("t", 200), summary = "s", verify_hint = "v", steps = { steps[1] } }))
	assert(#plan.title == 80, "title trimmed to 80, got " .. #plan.title)
	assert(plan.steps[1].n == 1 and plan.steps[1].included == true, "steps numbered and included")
	local _, e2 = validatePlan({ title = "t", summary = "s", verify_hint = "v", steps = { { title = "x", action = "edit", targets = {}, detail = "d", risk = "low" } } })
	assert(e2 and e2:find("targets", 1, true), "empty targets rejected")
end)
SelfTest.case("agent: system message is byte-stable", function()
	local a = SYS_GOAL
	local b = SYS_GOAL
	assert(a == b and #a > 500, "constant")
	assert(not buildGoalUserBlock("PHASE X"):find(SYS_GOAL:sub(1, 40), 1, true), "variable block does not repeat the system text")
end)
```
Reload with `DEV = true`. Expected: two FAIL lines.

- [ ] **Step 2: The prompts and the variable block**

```lua
local SYS_GOAL = [==[You are RoScript Pro Goal Mode, an engineering agent working INSIDE Roblox Studio through tools. You never see the screen; you read the place through index/inspect/read_script/search/read_output and change it only through the write tools.

Rules:
- Work in phases. In PLANNING you may only read; finish by calling submit_plan. In ACTING you execute exactly one approved step; finish by calling finish_step. In RECORDING you call write_memory once.
- Targets are full paths (ServerScriptService.Shop) or refs (#r17) exactly as tools emitted them. Never invent paths.
- Prefer replace_lines (anchored to read_script's hash) or edit_script over write_script. Never rewrite a file you have not read.
- You cannot destroy anything. trash moves instances to a recoverable folder; Jasper empties it.
- Source you write must be valid Luau; a syntax error is refused. Keep Roblox conventions: server logic in ServerScriptService, client logic in StarterPlayerScripts/StarterGui LocalScripts, shared modules in ReplicatedStorage.
- ServerStorage.RoScriptPro is this plugin's memory store. Read it through read_memory/list_plans/read_plan, never edit it.
- Facts in memory are plugin-measured and win over Notes on conflict.
- Be economical: one index at depth 1, then drill only where the goal points. Say what you did in finish_step, plainly, no praise.]==]

local function goalFacts()
	local facts, _ = Store.readMemory()
	return facts
end

-- Everything variable goes in the FIRST USER message (§6.6), never in the system message.
local function buildGoalUserBlock(phaseInstruction)
	local parts = {}
	local facts, notes = Store.readMemory()
	table.insert(parts, "=== MEMORY: FACTS ===\n" .. (facts ~= "" and facts or "(none yet)"))
	table.insert(parts, "=== MEMORY: NOTES ===\n" .. (notes ~= "" and notes or "(none yet)"))
	local page = Store.listPlans(0)
	local summaries = {}
	for i = 1, math.min(PLANS_FED_TO_PLAN, #page) do
		local rec = Store.readPlan(page[i].id)
		if rec then
			local s = ("%s [%s] %s"):format(rec.id, rec.status, rec.summary or "")
			for _, st in ipairs(rec.steps or {}) do
				if st.status == "failed" or st.status == "stopped" then s ..= ("\n  step %d %s: %s"):format(st.n, st.status, st.outcome or "") end
			end
			for _, rv in ipairs(rec.revisions or {}) do
				if rv.note then s ..= "\n  revision note: " .. rv.note end
			end
			table.insert(summaries, s)
		end
	end
	table.insert(parts, "=== RECENT PLANS ===\n" .. (#summaries > 0 and table.concat(summaries, "\n") or "(none)"))
	local sel = buildSelectionSummary()
	if sel then table.insert(parts, "=== SELECTION ===\n" .. sel) end
	local active = StudioService.ActiveScript
	if active then
		local n = select(2, Tools.readSource(active):gsub("\n", "")) + 1
		table.insert(parts, ("=== ACTIVE SCRIPT ===\n%s (%s, %d lines) %s"):format(active:GetFullName(), active.ClassName, n, Tools.ref(active)))
	end
	if S.get("goal_focus", { bugs = true, quality = true }).bugs then
		local o = Tools.read.read_output({ count = 40 })
		if o.ok and #o.lines > 0 then table.insert(parts, "=== RECENT OUTPUT ERRORS ===\n" .. table.concat(o.lines, "\n")) end
	end
	local idx = Tools.read.index({ path = "game", depth = 1 })
	table.insert(parts, "=== TOP-LEVEL INDEX ===\n" .. (idx.ok and idx.text or ""))
	table.insert(parts, "=== PHASE ===\n" .. phaseInstruction)
	return table.concat(parts, "\n\n")
end
```
Delete the unused `goalFacts` helper before committing (it is shown only to make the read explicit).

- [ ] **Step 3: Plan validation and the PLANNING loop**

```lua
local ACTIONS = { edit = true, create = true, move = true, trash = true, props = true, mixed = true }
local RISKS = { low = true, medium = true, high = true }
local function validatePlan(obj)
	if type(obj) ~= "table" or type(obj.steps) ~= "table" then return nil, "plan must have steps" end
	if #obj.steps == 0 then return nil, "plan has no steps" end
	if #obj.steps > MAX_STEPS then return nil, ("at most %d steps, got %d"):format(MAX_STEPS, #obj.steps) end
	local plan = { title = utf8Trim(tostring(obj.title or "Untitled"), 80), summary = utf8Trim(tostring(obj.summary or ""), 600), verify_hint = utf8Trim(tostring(obj.verify_hint or ""), 200), steps = {} }
	for i, s in ipairs(obj.steps) do
		if type(s) ~= "table" then return nil, "step " .. i .. " is not an object" end
		if not ACTIONS[s.action] then return nil, ("step %d has unknown action %s"):format(i, tostring(s.action)) end
		if type(s.targets) ~= "table" or #s.targets == 0 then return nil, ("step %d needs at least one target in targets"):format(i) end
		plan.steps[i] = { n = i, title = utf8Trim(tostring(s.title or ""), 80), action = s.action, targets = s.targets, detail = utf8Trim(tostring(s.detail or ""), 500), risk = RISKS[s.risk] and s.risk or "medium", included = true }
	end
	return plan
end

local FOCUS_LABELS = { bugs = "Bugs and errors", quality = "Code quality", perf = "Performance", ideas = "Gameplay ideas", polish = "Polish" }
local function focusText()
	local f = S.get("goal_focus", { bugs = true, quality = true })
	local out = {}
	for _, id in ipairs({ "bugs", "quality", "perf", "ideas", "polish" }) do
		if f[id] then table.insert(out, FOCUS_LABELS[id]) end
	end
	if #out == 0 then for _, id in ipairs({ "bugs", "quality", "perf", "ideas", "polish" }) do table.insert(out, FOCUS_LABELS[id]) end end
	return table.concat(out, ", ")
end

local function newPhaseState(phase, calls)
	local b = budgetFor(S.get("goal_effort", "normal"))
	return { phase = phase, budget = { calls = calls, tokens = b.tokens }, used = { calls = 0, tokens = 0 }, consecutiveErrors = 0, turns = 0, nudged = false, myGen = Goal.gen }
end

-- Generic tool loop for one phase. onControl(name, args) returns true to end the phase.
local function runPhaseLoop(convo, ps, tools, controlName, onControl)
	local maxTurns = ps.budget.calls + 2
	while true do
		if not Agent.checkGen(ps.myGen) then return false, "stopped" end
		if ps.exhausted then return false, "budget" end
		if ps.consecutiveErrors >= MAX_CONSECUTIVE_TOOL_ERRORS then return false, "three consecutive tool errors" end
		ps.turns += 1
		if ps.turns > maxTurns then return false, "too many model turns" end
		local result, err = requestWithWaits(convo, ps, tools)
		if not result then return false, err end
		local assistant = { role = "assistant", content = result.text or "", tool_calls = result.toolCalls, reasoning = result.reasoning }
		table.insert(convo.messages, assistant)
		if result.truncated and result.toolCalls then
			for _, c in ipairs(result.toolCalls) do
				table.insert(convo.messages, { role = "tool", tool_call_id = c.id, content = HttpService:JSONEncode({ ok = false, error = "tool call cut off by the output limit; use replace_lines or edit_script, or split the change", attributable = false }) })
			end
			continue
		end
		if not result.toolCalls then
			if ps.nudged then return false, "model stopped calling tools" end
			ps.nudged = true
			table.insert(convo.messages, { role = "user", content = ("Call %s to finish, or continue with tools."):format(controlName) })
			continue
		end
		ps.nudged = false
		local results, control = runToolBatch(result.toolCalls, ps)
		for _, r in ipairs(results) do
			table.insert(convo.messages, { role = "tool", tool_call_id = r.id, content = r.content })
		end
		if control and control.name == controlName then
			local done, msg = onControl(control.args)
			if done then return true end
			table.insert(convo.messages, { role = "user", content = msg }) -- one correction round
		end
	end
end

function Agent.plan(goalText)
	if Goal.phase ~= "IDLE" then return end
	if RunService:IsRunning() then GoalUI.log("stop the playtest first", "error"); return end
	local root, err = Store.ensure()
	if not root then GoalUI.log(err, "error"); return end
	Goal.gen += 1
	Goal.phase = "PLANNING"
	Goal.goalText = goalText or ""
	Goal.plan, Goal.revisions, Goal.steps, Goal.verify, Goal.models, Goal.estTokens = nil, {}, {}, nil, {}, 0
	GoalUI.setBusy(true)
	local instruction
	if #Goal.goalText > 0 then
		instruction = ("GOAL: %s\nFocus areas: %s\nInvestigate with the read tools until you can write a plan of at most %d steps. Each step must name its targets by path or #ref; selected instances and the active script are the likely targets when the goal says 'this'. Prefer replace_lines or edit_script over rewrites. Mark risk honestly. Then call submit_plan."):format(Goal.goalText, focusText(), MAX_STEPS)
	else
		instruction = ("PLAN NEXT: propose the most valuable improvements along these focus areas: %s. Read what you need, then call submit_plan with at most %d steps."):format(focusText(), MAX_STEPS)
	end
	local convo = { messages = { { role = "system", content = SYS_GOAL }, { role = "user", content = buildGoalUserBlock(instruction) } } }
	Goal.planConvo = convo
	local ps = newPhaseState("PLANNING", budgetFor(S.get("goal_effort", "normal")).plan)
	task.spawn(function()
		local tools = Schemas.forPhase("PLANNING")
		local ok, why = runPhaseLoop(convo, ps, tools, "submit_plan", function(args)
			local plan, verr = validatePlan(args)
			if not plan then return false, "Plan rejected: " .. verr .. ". Call submit_plan again." end
			Goal.plan = plan
			return true
		end)
		if not Agent.checkGen(ps.myGen) then return end
		Goal.estTokens += ps.used.tokens
		if not ok and why == "budget" then
			-- one last chance: submit_plan only (§6.3)
			table.insert(convo.messages, { role = "user", content = "Budget reached. Submit the best plan you can from what you have read; mark uncertain steps risk: high. Call submit_plan now." })
			local ps2 = newPhaseState("PLANNING", 1)
			ps2.myGen = ps.myGen
			ok, why = runPhaseLoop(convo, ps2, { Schemas.tool("submit_plan") }, "submit_plan", function(args)
				local plan, verr = validatePlan(args)
				if not plan then return false, verr end
				Goal.plan = plan
				return true
			end)
			if not Agent.checkGen(ps.myGen) then return end
		end
		GoalUI.setBusy(false)
		if ok then
			Goal.phase = "AWAITING_APPROVAL"
			GoalUI.setPhase("AWAITING_APPROVAL", "plan ready")
			GoalUI.showCard("plan", Goal.plan)
		else
			Goal.phase = "IDLE"
			GoalUI.setPhase("IDLE", "planning failed: " .. tostring(why))
			GoalUI.log("planning failed: " .. tostring(why), "error")
		end
	end)
end

function Agent.revise(note)
	if Goal.phase ~= "AWAITING_APPROVAL" or not Goal.planConvo then return end
	table.insert(Goal.revisions, { plan = Goal.plan, note = note, at = os.time() })
	Goal.gen += 1
	Goal.phase = "PLANNING"
	GoalUI.setBusy(true)
	local convo = Goal.planConvo
	table.insert(convo.messages, { role = "user", content = "[revision note] " .. note .. "\nRevise the plan and call submit_plan again." })
	local ps = newPhaseState("REVISING", budgetFor(S.get("goal_effort", "normal")).revise)
	task.spawn(function()
		local ok, why = runPhaseLoop(convo, ps, Schemas.forPhase("REVISING"), "submit_plan", function(args)
			local plan, verr = validatePlan(args)
			if not plan then return false, "Plan rejected: " .. verr .. ". Call submit_plan again." end
			Goal.plan = plan
			return true
		end)
		if not Agent.checkGen(ps.myGen) then return end
		Goal.estTokens += ps.used.tokens
		GoalUI.setBusy(false)
		Goal.phase = ok and "AWAITING_APPROVAL" or "IDLE"
		if ok then GoalUI.showCard("plan", Goal.plan) else GoalUI.log("revise failed: " .. tostring(why), "error") end
	end)
end

function Agent.cancel()
	if Goal.phase ~= "AWAITING_APPROVAL" then return end
	Goal.gen += 1
	Goal.phase = "RECORDING"
	Agent.record("cancelled") -- Task 9; until then define a stub: function Agent.record(status) Goal.phase = "IDLE"; GoalUI.setPhase("IDLE", status) end
end

function Agent.stop()
	Goal.gen += 1
	local rec = Goal.openRecording
	if rec and rec.owner ~= coroutine.running() then
		-- the owning batch coroutine cancels at its next gen check (§8.3); nothing to do here
	end
	if Goal.verifyConn then Goal.verifyConn:Disconnect(); Goal.verifyConn = nil end
	GoalUI.setBusy(false)
	if Goal.phase == "PLANNING" or Goal.phase == "AWAITING_APPROVAL" then
		Goal.phase = "IDLE" -- a Stop before submit_plan writes no record
		GoalUI.setPhase("IDLE", "stopped")
	elseif Goal.phase ~= "IDLE" then
		Goal.phase = "RECORDING"
		Agent.record("stopped")
	end
end
```
Add the temporary `Agent.record` stub right after `local Agent = {}` (Task 9 replaces it).

- [ ] **Step 4: Goal view, chips, plan card, prompt modal (section 11)**

Shared state and the two views:
```lua
local goalView, chatView, goalBox, goalScroll, planButton, phaseLabel, stopGoalButton
local chipButtons = {}
local FOCUS_IDS = { "bugs", "quality", "perf", "ideas", "polish" }

local function hoverable(btn, base, hover)
	btn.MouseEnter:Connect(function() btn.BackgroundColor3 = hover end)
	btn.MouseLeave:Connect(function() btn.BackgroundColor3 = base end)
end
local function button(text, parent, size, pos, onClick)
	local b = mk("TextButton", { BackgroundColor3 = C.PANEL2, Size = size, Position = pos, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, Text = text, AutoButtonColor = false }, parent)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
	hoverable(b, C.PANEL2, C.ACCENT)
	b.MouseButton1Click:Connect(onClick)
	return b
end
local function card(title)
	local f = mk("Frame", { BackgroundColor3 = C.PANEL, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = #goalScroll:GetChildren() }, goalScroll)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, f)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, f)
	mk("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, f)
	mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = title, LayoutOrder = 0 }, f)
	return f
end
local function label(parent, text, color, order)
	return mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = color or C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, RichText = true, Text = escapeRich(text), LayoutOrder = order or 1 }, parent)
end

local function buildGoalView(root)
	goalView = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32), Visible = false }, root)
	goalBox = mk("TextBox", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, -16, 0, 60), Position = UDim2.new(0, 8, 0, 8), Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, MultiLine = true, ClearTextOnFocus = false, PlaceholderText = "Describe the goal… or leave empty and press Plan next", PlaceholderColor3 = C.MUTED, Text = "" }, goalView)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, goalBox)
	local chips = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0, 74) }, goalView)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, chips)
	local focus = S.get("goal_focus", { bugs = true, quality = true })
	for _, id in ipairs(FOCUS_IDS) do
		local on = focus[id] == true
		local b = mk("TextButton", { BackgroundColor3 = on and C.ACCENT or C.PANEL2, Size = UDim2.new(0, 66, 1, 0), Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = C.TEXT, Text = FOCUS_LABELS[id], AutoButtonColor = false }, chips)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
		b.MouseButton1Click:Connect(function()
			local f = S.get("goal_focus", { bugs = true, quality = true })
			f[id] = not f[id] or nil
			S.set("goal_focus", f)
			b.BackgroundColor3 = f[id] and C.ACCENT or C.PANEL2
		end)
		chipButtons[id] = b
	end
	local row = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 24), Position = UDim2.new(0, 8, 0, 102) }, goalView)
	planButton = button("Plan next", row, UDim2.new(0, 90, 1, 0), UDim2.new(0, 0, 0, 0), function()
		Agent.plan(goalBox.Text)
	end)
	goalBox:GetPropertyChangedSignal("Text"):Connect(function()
		planButton.Text = (#goalBox.Text:gsub("%s", "") > 0) and "Plan" or "Plan next"
	end)
	stopGoalButton = button("Stop", row, UDim2.new(0, 50, 1, 0), UDim2.new(0, 96, 0, 0), function() Agent.stop() end)
	stopGoalButton.Visible = false
	phaseLabel = mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -160, 1, 0), Position = UDim2.new(0, 152, 0, 0), Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Text = "idle" }, row)
	goalScroll = mk("ScrollingFrame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -134), Position = UDim2.new(0, 0, 0, 132), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6 }, goalView)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, goalScroll)
	mk("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, goalScroll)
end
```
GoalUI fills:
```lua
GoalUI.setPhase = function(phase, detail)
	if not phaseLabel then return end
	local r = Goal.requests
	local counters = ("req G%d C%d O%d"):format(r.groq or 0, r.cerebras or 0, r.openrouter or 0)
	phaseLabel.Text = phase:lower() .. (detail and (" · " .. detail) or "") .. " · " .. counters
end
GoalUI.setBusy = function(busy)
	if planButton then planButton.Active = not busy; planButton.TextColor3 = busy and C.MUTED or C.TEXT end
	if stopGoalButton then stopGoalButton.Visible = busy end
end
GoalUI.log = function(text, kind)
	local color = kind == "error" and C.ERR or kind == "ok" and C.OK or kind == "muted" and C.MUTED or C.TEXT
	if not goalScroll then return end
	local logCard = goalScroll:FindFirstChild("ActLog") or card("Act log")
	logCard.Name = "ActLog"
	label(logCard, text, color, #logCard:GetChildren())
end
-- Blocking prompt: returns "allow" | "skip" | "stop". Runs in the calling coroutine (a batch, before its recording opens).
GoalUI.prompt = function(kind, payload)
	local answer = nil
	local panel = openModalPanel(payload.title or kind)
	local body = mk("ScrollingFrame", { BackgroundColor3 = C.CODEBG, Size = UDim2.new(1, -16, 1, -80), Position = UDim2.new(0, 8, 0, 34), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6 }, panel)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, body)
	for i, chunk in ipairs(chunkText(payload.text or "")) do
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Code, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, RichText = true, Text = escapeRich(chunk), LayoutOrder = i }, body)
	end
	local y = UDim2.new(1, -36, 0, 0)
	button("Allow", panel, UDim2.new(0, 80, 0, 26), UDim2.new(0, 8, 1, -34), function() answer = "allow" end)
	button("Skip this call", panel, UDim2.new(0, 100, 0, 26), UDim2.new(0, 96, 1, -34), function() answer = "skip" end)
	button("Stop plan", panel, UDim2.new(0, 80, 0, 26), UDim2.new(1, -88, 1, -34), function() answer = "stop" end)
	while answer == nil and widgetAlive() do task.wait(0.05) end
	closeModal()
	return answer or "stop"
end
```
`openModalPanel` in v1 returns the panel; confirm by reading its last line (`return panel`) and add the return if missing. The plan card:
```lua
local RISK_COLOR = { low = C.OK, medium = Color3.fromHex("f59e0b"), high = C.ERR }
local function showPlanCard(plan)
	local old = goalScroll:FindFirstChild("PlanCard"); if old then old:Destroy() end
	local f = card(plan.title); f.Name = "PlanCard"
	label(f, plan.summary, C.TEXT, 1)
	if #plan.verify_hint > 0 then label(f, "Verify: " .. plan.verify_hint, C.MUTED, 2) end
	for i, s in ipairs(plan.steps) do
		local row = mk("Frame", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 10 + i }, f)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, row)
		local box = mk("TextButton", { BackgroundColor3 = C.ACCENT, Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(0, 4, 0, 4), Text = "", AutoButtonColor = false }, row)
		box.MouseButton1Click:Connect(function()
			s.included = not s.included
			box.BackgroundColor3 = s.included and C.ACCENT or C.PANEL
			local any = false
			for _, st in ipairs(plan.steps) do any = any or st.included end
			f.Approve.Active = any; f.Approve.TextColor3 = any and C.TEXT or C.MUTED
		end)
		mk("Frame", { BackgroundColor3 = RISK_COLOR[s.risk], Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, 26, 0, 8) }, row)
		local t = mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -110, 1, 0), Position = UDim2.new(0, 40, 0, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("%d. %s  [%s]  %s"):format(s.n, s.title, s.action, table.concat(s.targets, ", ")) }, row)
		button("View", row, UDim2.new(0, 44, 0, 18), UDim2.new(1, -50, 0, 3), function()
			GoalUI.prompt("detail", { title = ("Step %d"):format(s.n), text = s.detail .. "\n\nTargets:\n" .. table.concat(s.targets, "\n") })
		end)
	end
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 99 }, f)
	local approve = button("Approve", bar, UDim2.new(0, 80, 1, 0), UDim2.new(0, 0, 0, 0), function()
		if Goal.phase ~= "AWAITING_APPROVAL" then return end
		goalBox.Text = ""
		Agent.approve() -- Task 8
	end)
	approve.Name = "Approve"; approve.Parent = f -- so the include toggles can find it
	approve.Parent = bar
	button("Revise", bar, UDim2.new(0, 70, 1, 0), UDim2.new(0, 86, 0, 0), function()
		local note = nil
		local panel = openModalPanel("Revision note")
		local box = mk("TextBox", { BackgroundColor3 = C.CODEBG, Size = UDim2.new(1, -16, 0, 80), Position = UDim2.new(0, 8, 0, 34), Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.TEXT, TextWrapped = true, MultiLine = true, ClearTextOnFocus = false, Text = "" }, panel)
		button("Send", panel, UDim2.new(0, 70, 0, 26), UDim2.new(0, 8, 0, 122), function() note = box.Text end)
		while note == nil and widgetAlive() do task.wait(0.05) end
		closeModal()
		if note and #note > 0 then Agent.revise(note) end
	end)
	button("Cancel", bar, UDim2.new(0, 70, 1, 0), UDim2.new(0, 162, 0, 0), function() f:Destroy(); Agent.cancel() end)
end
GoalUI.showCard = function(kind, data)
	if kind == "plan" then showPlanCard(data) end
end
```
The Revise button's blocking loop runs on the UI thread that handled the click, which is fine in Studio plugins (`MouseButton1Click` handlers may yield). Note the `Approve` button lookup uses `f.Approve`; keep `approve.Name = "Approve"` and parent it under `bar` (fix the two-line dance above to a single `approve.Name = "Approve"` and `f:FindFirstChild("Approve", true)` in the toggle handler).

- [ ] **Step 5: Wire the Chat|Goal toggle and unload cleanup (section 12)**

In `buildUI(w)` (section 7) the chat elements are parented to `root`. Wrap them: after `local root = mk("Frame", …)` add `chatView = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32) }, root)` and parent `chatScroll` and `inputBar` to `chatView` instead of `root` (two edits). Add a toggle button in the top bar left of `ctxButton`:
```lua
	local modeButton = mk("TextButton", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(0, 64, 0, 22), Position = UDim2.new(1, -170, 0, 4), Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = C.TEXT, Text = S.get("goal_mode", false) and "Goal" or "Chat", AutoButtonColor = false }, topBar)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, modeButton)
	local function setGoalMode(on)
		S.set("goal_mode", on)
		modeButton.Text = on and "Goal" or "Chat"
		chatView.Visible = not on
		goalView.Visible = on
		ctxButton.TextColor3 = on and C.MUTED or C.TEXT
	end
	modeButton.MouseButton1Click:Connect(function() setGoalMode(not S.get("goal_mode", false)) end)
	modeButton.MouseEnter:Connect(function() modeButton.BackgroundColor3 = C.ACCENT end)
	modeButton.MouseLeave:Connect(function() modeButton.BackgroundColor3 = C.PANEL2 end)
```
At the end of `buildUI`, call `buildGoalView(root)` then `setGoalMode(S.get("goal_mode", false))`. Since `buildGoalView` is defined in section 11 (after section 7), forward-declare `local buildGoalView` next to the other UI locals in section 7 and assign `buildGoalView = function(root) … end` in section 11. In BOOTSTRAP's `plugin.Unloading` handler add:
```lua
	Goal.gen += 1
	if Goal.verifyConn then Goal.verifyConn:Disconnect() end
	if Goal.openRecording then
		pcall(function() ChangeHistoryService:FinishRecording(Goal.openRecording.id, Enum.FinishRecordingOperation.Cancel) end)
	end
	Tools.clearRefs()
```

- [ ] **Step 6: Reload and verify**

Expected: the two new `agent:` cases PASS. Studio check in a scratch place with one Groq or Cerebras key: toggle to Goal, type "Add a Part named Beacon to Workspace that glows", press Plan. Expected: phase label cycles through `planning · Thinking — …`, a plan card appears with 1–3 steps, include toggles work, View opens the detail modal, Revise with "make it red" produces a second card mentioning red, Cancel clears it. `ServerStorage.RoScriptPro` exists with `RSP_StoreVersion = 1`.

- [ ] **Step 7: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: PLANNING phase, Revise/Cancel, Goal view with chips, plan card, prompt modal, Chat|Goal toggle"
```

---

### Task 7: TOOLS write set + the recording-gated Executor

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `9. TOOLS` (append), replace the `Executor` stub in `10. AGENT`.

**Interfaces:**
- Consumes: `Tools.resolve`, `Tools.readSource`, `Tools.decodeValue`, `Tools.propsFor`, `Store.trash`, `Store.root`, `GoalUI.prompt`, `Goal` (`plan`, `openRecording`, `gen`, `currentStep`), `ChangeHistoryService`, `ScriptEditorService`, `S.get("goal_careful")`.
- Produces:
  - `Tools.syntaxCheck(source: string) -> ok: boolean, err: string?`
  - `Tools.lineDiffPercent(a: string, b: string) -> number` (0–100, line-set diff)
  - `Tools.write.<name>(args, ctx) -> result` for `replace_lines, edit_script, write_script, create, set_props, move, trash`; `ctx = { planId, step, simulated: { [Instance]: source } }`
  - `Executor.runWriteBatch(writes: {{index, name, args}}, ps) -> results: { [index]: result }, committed: boolean` — pre-walk, prompts, one recording, execute, bookkeeping into `Goal.steps[ps.step.n].changed/writes`, `beforeSources`
  - `Executor.isOffTarget(inst: Instance, step) -> boolean`
- Invariants: no recording ⇒ no write; `UpdateSourceAsync` is the only yield inside the recording and is followed by `Agent.checkGen`; only the opening coroutine finishes the recording; writes refused while `RunService:IsRunning()`.

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("tools: syntax gate", function()
	assert(Tools.syntaxCheck("local x = 1\nprint(x)") == true, "valid")
	local ok, err = Tools.syntaxCheck("if true then\nprint(1)")
	assert(ok == false and err and #err > 0, "missing end detected")
end)
SelfTest.case("tools: line diff percent", function()
	local a = "a\nb\nc\nd"
	assert(Tools.lineDiffPercent(a, a) == 0, "same")
	assert(Tools.lineDiffPercent(a, "a\nb\nX\nY") == 50, "half, got " .. Tools.lineDiffPercent(a, "a\nb\nX\nY"))
	assert(Tools.lineDiffPercent(a, "") == 100, "all")
end)
SelfTest.case("executor: off-target detection uses ancestors", function()
	withScratch(function(f)
		local m = Instance.new("Model"); m.Name = "Lobby"; m.Parent = f
		local p = Instance.new("Part"); p.Name = "Door"; p.Parent = m
		local step = { n = 1, targets = { "ServerStorage.RSP_TestScratch.Lobby" } }
		assert(Executor.isOffTarget(p, step) == false, "descendant of a declared target is on-target")
		assert(Executor.isOffTarget(f, step) == true, "ancestor of the target is off-target")
		local step2 = { n = 1, targets = { Tools.ref(p) } }
		assert(Executor.isOffTarget(p, step2) == false, "ref target")
	end)
end)
SelfTest.case("executor: batch under one recording, rollback on throw", function()
	withScratch(function(f)
		local s = Instance.new("Script"); s.Name = "S"; s.Source = "print(1)"; s.Parent = f
		Goal.plan = { steps = { { n = 1, targets = { "ServerStorage.RSP_TestScratch" }, risk = "low" } } }
		Goal.steps = { { n = 1, changed = {}, writes = {}, undoLabels = {} } }
		local ps = { phase = "ACTING", step = Goal.plan.steps[1], myGen = Goal.gen, used = { calls = 0, tokens = 0 }, budget = { calls = 99, tokens = 1e9 }, consecutiveErrors = 0 }
		local results, committed = Executor.runWriteBatch({
			{ index = 1, name = "write_script", args = { target = "ServerStorage.RSP_TestScratch.S", source = "print(2)" } },
			{ index = 2, name = "set_props", args = { targets = { "ServerStorage.RSP_TestScratch.S" }, props = { { name = "Nope", value = "1" } } } },
		}, ps)
		assert(committed == true, "committed")
		assert(results[1].ok and s.Source == "print(2)", "script written")
		assert(results[2].ok == true and results[2].rejected.Nope, "non-whitelisted prop reported, call still ok")
		assert(#Goal.steps[1].changed == 1 and Goal.steps[1].changed[1].hashBefore ~= Goal.steps[1].changed[1].hashAfter, "changed bookkeeping")
		local r2, c2 = Executor.runWriteBatch({
			{ index = 1, name = "write_script", args = { target = "ServerStorage.RSP_TestScratch.S", source = "print(3)" } },
			{ index = 2, name = "move", args = { targets = { "ServerStorage.RSP_TestScratch.S" }, newParent = "ServerStorage.DoesNotExist" } },
		}, ps)
		assert(c2 == false and s.Source == "print(2)", "batch rolled back when a write throws")
		assert(r2[1].ok == false and r2[1].error:find("rolled back", 1, true), "collateral marked")
		Goal.plan, Goal.steps = nil, {}
	end)
end)
```
Reload with `DEV = true`. Expected: four FAIL lines.

- [ ] **Step 2: Syntax gate, diff, source writer**

```lua
do
	function Tools.syntaxCheck(source)
		local fn, err = loadstring(source)
		if fn then return true end
		return false, tostring(err)
	end

	function Tools.lineDiffPercent(a, b)
		local la, lb = a:split("\n"), b:split("\n")
		local set = {}
		for _, l in ipairs(la) do set[l] = (set[l] or 0) + 1 end
		local same = 0
		for _, l in ipairs(lb) do
			if set[l] and set[l] > 0 then same += 1; set[l] -= 1 end
		end
		local total = math.max(#la, #lb, 1)
		return math.floor((1 - same / total) * 100 + 0.5)
	end

	-- Writes source through UpdateSourceAsync (S1 route: unopened scripts may use .Source instead).
	-- Returns ok, err. Caller holds the recording and re-checks gen after this returns.
	local USE_SOURCE_FOR_UNOPENED = false -- flip to true if S1 shows no undo for unopened scripts
	function Tools.writeSource(script, compute)
		local isOpen = ScriptEditorService:FindScriptDocument(script) ~= nil
		if USE_SOURCE_FOR_UNOPENED and not isOpen then
			local new, cerr = compute(script.Source)
			if not new then return false, cerr end
			script.Source = new
			return true
		end
		local computeErr
		local ok, err = pcall(function()
			ScriptEditorService:UpdateSourceAsync(script, function(old)
				local new, e = compute(old)
				if not new then computeErr = e; return old end -- unchanged
				return new
			end)
		end)
		if not ok then return false, tostring(err) end
		if computeErr then return false, computeErr end
		return true
	end
end
```

- [ ] **Step 3: The write tools**

Each returns a result table and never touches the recording itself; `ctx.simulated[inst]` carries the source as earlier calls in the same batch left it (pre-walk) so later calls see earlier edits.
```lua
do
	local function scriptTarget(target)
		local inst, err = Tools.resolve(target)
		if not inst then return nil, err end
		if not inst:IsA("LuaSourceContainer") then return nil, "not a script: " .. inst.ClassName end
		return inst
	end
	local function protected(inst)
		local root = Store.root()
		return (root and inst:IsDescendantOf(root)) or inst:IsDescendantOf(game:GetService("CoreGui"))
	end
	local function currentSource(inst, ctx)
		return (ctx and ctx.simulated and ctx.simulated[inst]) or Tools.readSource(inst)
	end
	local function applySource(inst, newSource, ctx, tool, extra)
		local okS, serr = Tools.syntaxCheck(newSource)
		if not okS then return { ok = false, error = "syntax error: " .. serr } end
		if ctx.dryRun then ctx.simulated[inst] = newSource; return { ok = true, dry = true, newSource = newSource } end
		local ok, err = Tools.writeSource(inst, function() return newSource end)
		if not ok then return { ok = false, error = err } end
		ctx.simulated[inst] = newSource
		local r = { ok = true, path = inst:GetFullName(), ref = Tools.ref(inst), hash = Store.hash(newSource), tool = tool }
		for k, v in pairs(extra or {}) do r[k] = v end
		return r
	end

	function Tools.write.replace_lines(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		local src = currentSource(inst, ctx)
		if Store.hash(src) ~= tostring(args.expectHash) then return { ok = false, error = "expectHash does not match the current source; read_script again" } end
		local lines = src:split("\n")
		local from, to = tonumber(args.fromLine), tonumber(args.toLine)
		if not from or not to or from < 1 or to < from or to > #lines then return { ok = false, error = ("line range out of bounds (1..%d)"):format(#lines) } end
		local out = {}
		for i = 1, from - 1 do table.insert(out, lines[i]) end
		for _, l in ipairs(tostring(args.newText or ""):split("\n")) do table.insert(out, l) end
		for i = to + 1, #lines do table.insert(out, lines[i]) end
		return applySource(inst, table.concat(out, "\n"), ctx, "replace_lines", { from = from, to = to, newLines = select(2, tostring(args.newText or ""):gsub("\n", "")) + 1 })
	end

	function Tools.write.edit_script(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		local src = currentSource(inst, ctx)
		local find, rep = tostring(args.find or ""), tostring(args.replace or "")
		if #find == 0 then return { ok = false, error = "empty find" } end
		local first = src:find(find, 1, true)
		if not first then
			-- nearest: best single-line match of find's first non-blank line
			local probe = find:match("([^\n]*%S[^\n]*)") or find
			local lines = src:split("\n")
			local bestI = nil
			for i, l in ipairs(lines) do if l:find(probe, 1, true) then bestI = i; break end end
			local near = {}
			if bestI then for i = math.max(1, bestI - 3), math.min(#lines, bestI + 3) do table.insert(near, i .. "\t" .. lines[i]) end end
			return { ok = false, error = "find not found", nearest = table.concat(near, "\n") }
		end
		local second = src:find(find, first + #find, true)
		if second and not args.all then
			local count, pos, ln = 0, 1, {}
			while true do local s = src:find(find, pos, true); if not s then break end; count += 1; table.insert(ln, select(2, src:sub(1, s):gsub("\n", "")) + 1); pos = s + #find end
			return { ok = false, error = ("find matches %d times; set all=true or make it unique"):format(count), lines = ln }
		end
		local new
		if args.all then
			new = src:gsub(find:gsub("%W", "%%%0"), (rep:gsub("%%", "%%%%")))
		else
			new = src:sub(1, first - 1) .. rep .. src:sub(first + #find)
		end
		return applySource(inst, new, ctx, "edit_script", { find = utf8Trim(find, 400), replace = utf8Trim(rep, 400) })
	end

	function Tools.write.write_script(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		local new = tostring(args.source or "")
		local old = currentSource(inst, ctx)
		return applySource(inst, new, ctx, "write_script", { linesChanged = Tools.lineDiffPercent(old, new), newLines = select(2, new:gsub("\n", "")) + 1 })
	end

	local function applyProps(inst, props)
		local applied, rejected = {}, {}
		local allowed = Tools.propsFor(inst)
		for _, pair in ipairs(props or {}) do
			local name, raw = tostring(pair.name or ""), tostring(pair.value or "")
			if name:sub(1, 1) == "@" then
				local okD, v = pcall(function() return HttpService:JSONDecode(raw) end)
				local t = type(v)
				if okD and (t == "string" or t == "number" or t == "boolean") then inst:SetAttribute(name:sub(2), v); table.insert(applied, name)
				else rejected[name] = "attributes accept string, number, boolean JSON values" end
			elseif allowed[name] then
				local v, derr = Tools.decodeValue(raw, allowed[name])
				if v == nil then rejected[name] = derr else
					local okSet, serr = pcall(function() inst[name] = v end)
					if okSet then table.insert(applied, name) else rejected[name] = tostring(serr) end
				end
			else
				rejected[name] = "property not whitelisted — write a Script if it must change at runtime"
			end
		end
		return applied, rejected
	end

	function Tools.write.create(args, ctx)
		local parent, perr = Tools.resolve(args.parent); if not parent then return { ok = false, error = perr } end
		if protected(parent) then return { ok = false, error = "parent is protected" } end
		local okNew, inst = pcall(Instance.new, tostring(args.class))
		if not okNew then return { ok = false, error = "class not creatable: " .. tostring(args.class) } end
		inst.Name = tostring(args.name or args.class)
		if args.source ~= nil and inst:IsA("LuaSourceContainer") then
			local okS, serr = Tools.syntaxCheck(tostring(args.source))
			if not okS then inst:Destroy(); return { ok = false, error = "syntax error: " .. serr } end
			if ctx.dryRun then inst:Destroy(); return { ok = true, dry = true } end
			inst.Source = tostring(args.source) -- new instance: no editor document yet, .Source is the only route
		elseif ctx.dryRun then inst:Destroy(); return { ok = true, dry = true } end
		local applied, rejected = applyProps(inst, args.props)
		inst.Parent = parent
		return { ok = true, path = inst:GetFullName(), ref = Tools.ref(inst), created = true, applied = applied, rejected = rejected, tool = "create" }
	end

	local function eachTarget(args, fn)
		local targets = args.targets
		if type(targets) ~= "table" or #targets == 0 or #targets > 50 then return { ok = false, error = "targets must hold 1-50 entries" } end
		local per, anyOk = {}, false
		for _, t in ipairs(targets) do
			local inst, err = Tools.resolve(t)
			if not inst then per[t] = { ok = false, error = err }
			elseif protected(inst) then per[t] = { ok = false, error = "protected" }
			else per[t] = fn(inst); anyOk = anyOk or per[t].ok end
		end
		return { ok = anyOk, results = per }
	end

	function Tools.write.set_props(args, ctx)
		if ctx.dryRun then return { ok = true, dry = true } end
		local r = eachTarget(args, function(inst)
			local applied, rejected = applyProps(inst, args.props)
			return { ok = #applied > 0 or next(rejected) == nil, applied = applied, rejected = rejected, path = inst:GetFullName() }
		end)
		-- flatten for the single-target common case
		if type(args.targets) == "table" and #args.targets == 1 then
			local only = r.results[args.targets[1]]
			if only then only.ok = only.ok or #only.applied > 0; return only end
		end
		return r
	end

	function Tools.write.move(args, ctx)
		local newParent, perr = Tools.resolve(args.newParent); if not newParent then return { ok = false, error = perr } end
		if protected(newParent) then return { ok = false, error = "new parent is protected" } end
		if ctx.dryRun then return { ok = true, dry = true } end
		return eachTarget(args, function(inst)
			local from = inst.Parent and inst.Parent:GetFullName() or ""
			inst.Parent = newParent
			return { ok = true, path = inst:GetFullName(), origParent = from, moved = true }
		end)
	end

	function Tools.write.trash(args, ctx)
		if ctx.dryRun then return { ok = true, dry = true } end
		return eachTarget(args, function(inst)
			local from = inst.Parent and inst.Parent:GetFullName() or ""
			local path = inst:GetFullName()
			Store.trash(inst, ctx.planId)
			return { ok = true, path = path, origParent = from, trashed = true }
		end)
	end
end
```

- [ ] **Step 4: The Executor (replace the stub in section 10)**

```lua
local Executor = {}
do
	function Executor.isOffTarget(inst, step)
		for _, t in ipairs(step.targets or {}) do
			local declared = Tools.resolve(t)
			if declared and (inst == declared or inst:IsDescendantOf(declared)) then return false end
		end
		return true
	end

	-- Pre-walk (no writes): simulate sources, decide prompts. Returns prompts list and per-write skip set.
	local function preWalk(writes, ps, ctx)
		local prompts = {}
		local careful = S.get("goal_careful", false) == true
		for _, w in ipairs(writes) do
			local reason = nil
			local target = w.args.target or (type(w.args.targets) == "table" and w.args.targets[1]) or w.args.parent
			local inst = target and Tools.resolve(target)
			if inst and Executor.isOffTarget(inst, ps.step) then
				reason = ("%s targets %s, which the approved step did not declare"):format(w.name, inst:GetFullName())
			end
			if w.name == "trash" then
				for _, t in ipairs(w.args.targets or {}) do
					local i2 = Tools.resolve(t)
					if i2 and (#i2:GetDescendants() > 0 or i2:IsA("LuaSourceContainer")) then reason = reason or ("trash %s (%d descendants)"):format(i2:GetFullName(), #i2:GetDescendants()) end
				end
			elseif w.name == "write_script" and inst and inst:IsA("LuaSourceContainer") then
				local old = ctx.simulated[inst] or Tools.readSource(inst)
				local oldLines = select(2, old:gsub("\n", "")) + 1
				local pct = Tools.lineDiffPercent(old, tostring(w.args.source or ""))
				local declaredHigh = ps.step.risk == "high" and not Executor.isOffTarget(inst, ps.step)
				if oldLines > 200 and pct > 50 and not declaredHigh then reason = reason or ("rewrite %s: %d lines, %d%% changed"):format(inst:GetFullName(), oldLines, pct) end
			end
			if careful and not reason then reason = "Careful mode: " .. w.name end
			-- simulate so later calls in the batch see this one
			if inst and (w.name == "write_script" or w.name == "edit_script" or w.name == "replace_lines") then
				local dry = table.clone(ctx); dry.dryRun = true
				local r = Tools.write[w.name](w.args, dry)
				if r.ok and r.newSource then ctx.simulated[inst] = r.newSource end
			end
			if reason then table.insert(prompts, { write = w, reason = reason, inst = inst }) end
		end
		return prompts
	end

	local function describe(w)
		local a = table.clone(w.args)
		if a.source then a.source = utf8Trim(a.source, 3000) end
		if a.newText then a.newText = utf8Trim(a.newText, 3000) end
		return HttpService:JSONEncode(a)
	end

	function Executor.runWriteBatch(writes, ps)
		local results = {}
		local function refuseAll(msg, attributable)
			for _, w in ipairs(writes) do results[w.index] = { ok = false, error = msg, attributable = attributable } end
			return results, false
		end
		if RunService:IsRunning() then return refuseAll("writes refused while a playtest is running", false) end
		local step = ps.step
		local ctx = { planId = Goal.planId, step = step, simulated = {} }
		local skip = {}
		for _, p in ipairs(preWalk(writes, ps, ctx)) do
			local answer = GoalUI.prompt("write", { title = p.reason, text = describe(p.write) })
			if not Agent.checkGen(ps.myGen) then return refuseAll("stopped", false) end
			if answer == "stop" then Agent.stop(); return refuseAll("stopped by Jasper", false)
			elseif answer == "skip" then skip[p.write.index] = true end
		end
		ctx.simulated = {} -- real run recomputes
		local label = ("Step %d"):format(step.n) .. (ps.batches and ps.batches > 0 and (", part " .. (ps.batches + 1)) or "")
		local rec = ChangeHistoryService:TryBeginRecording("RoScriptPro " .. label, "RoScript Pro: " .. label)
		if not rec then return refuseAll("undo unavailable, writes refused", false) end
		Goal.openRecording = { id = rec, owner = coroutine.running() }
		ps.batches = (ps.batches or 0) + 1
		local bookkeeping = Goal.steps[step.n]
		local committed = true
		local failedAt = nil
		for _, w in ipairs(writes) do
			if skip[w.index] then
				results[w.index] = { ok = false, error = "skipped by Jasper", attributable = false }
			else
				-- capture before-state for Revert
				local target = w.args.target or (type(w.args.targets) == "table" and w.args.targets[1])
				local inst = target and Tools.resolve(target)
				local before = inst and inst:IsA("LuaSourceContainer") and Tools.readSource(inst) or nil
				local okCall, r = pcall(Tools.write[w.name], w.args, ctx)
				if not okCall then r = { ok = false, error = "write crashed: " .. tostring(r) }; failedAt = w.index end
				if not Agent.checkGen(ps.myGen) then
					-- UpdateSourceAsync may have yielded across a Stop: we own the recording, so we cancel it.
					ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Cancel)
					Goal.openRecording = nil
					return refuseAll("stopped", false)
				end
				results[w.index] = r
				if r.ok and inst and before then
					local k = #bookkeeping.changed + 1
					bookkeeping.beforeSources = bookkeeping.beforeSources or {}
					bookkeeping.beforeSources[k] = before
					table.insert(bookkeeping.changed, { path = r.path or inst:GetFullName(), ref = Tools.ref(inst), kind = "script", hashBefore = Store.hash(before), hashAfter = r.hash or Tools.hashOf(inst), before = "before/" .. k })
				elseif r.ok and (r.created or r.moved or r.trashed or r.results) then
					local entries = r.results or { [r.path or "?"] = r }
					for _, e in pairs(entries) do
						if e.ok then table.insert(bookkeeping.changed, { path = e.path, ref = e.ref, kind = "instance", origParent = e.origParent, created = e.created, trashed = e.trashed }) end
					end
				end
				if r.ok then
					local wr = { tool = w.name }
					for _, k in ipairs({ "from", "to", "newLines", "find", "replace", "linesChanged", "path" }) do wr[k] = r[k] end
					table.insert(bookkeeping.writes, wr)
				end
				if failedAt then break end
			end
		end
		if failedAt then
			ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Cancel)
			committed = false
			for _, w in ipairs(writes) do
				if w.index ~= failedAt and not skip[w.index] then results[w.index] = { ok = false, error = "batch rolled back", attributable = false } end
			end
			-- bookkeeping added during this batch is dropped
			bookkeeping.changed, bookkeeping.writes = {}, {}
			bookkeeping.beforeSources = nil
		else
			ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
			table.insert(bookkeeping.undoLabels, "RoScript Pro: " .. label)
		end
		Goal.openRecording = nil
		return results, committed
	end
end
```
Rollback bookkeeping note: a step may have several batches; the "dropped" reset above wipes earlier committed batches' entries too. Fix it in the same task: snapshot `#bookkeeping.changed` and `#bookkeeping.writes` before the loop and truncate back to those counts on rollback instead of clearing.

- [ ] **Step 5: Reload and verify green**

Expected: the four new cases PASS. The rollback case proves cancel reverts the first write of the batch. Studio check: after the test run, Ctrl+Z shows no leftover entries from the tests except the committed test batch (acceptable).

- [ ] **Step 6: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: write tools (syntax gate, replace_lines, edit_script, write_script, create, set_props, move, trash) and the recording-gated executor"
```

---

### Task 8: ACTING phase, act log, Retry/Continue, Stop semantics

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` sections `10. AGENT` (ACTING), `11. GOAL UI` (act log batch View, failure offers).

**Interfaces:**
- Consumes: Task 5 loop (`runPhaseLoop`, `newPhaseState`, `requestWithWaits`), Task 7 `Executor`, `Schemas.forPhase("ACTING")`, `buildGoalUserBlock`, `GoalUI.log`, `GoalUI.showCard`.
- Produces:
  - `Agent.approve()` — runs included steps in order, then `Agent.afterActing()`
  - `Agent.runStep(step) -> status: "done"|"failed"|"stopped", outcome: string` (one §8.1 conversation)
  - `Agent.retryStep(n)`, `Agent.continueFrom(n)`
  - `Agent.afterActing()` — decides VERIFYING vs RECORDING (§8.2); until Task 10 lands it always calls `Agent.record(...)`
  - `stepSeed(step) -> string` (the first user message of a step, with pre-injected sources up to `STEP_SEED_MAX`)
  - `Goal.planId` set at approve time (`Store.nextPlanId(plan.title)`), `Goal.steps[n] = { n, status, outcome, changed = {}, writes = {}, undoLabels = {} }`
  - `GoalUI.showCard("failure", { step })` renders Retry / Continue / Stop offers

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("agent: stepSeed pre-injects sources with head/tail cap", function()
	withScratch(function(f)
		local s = Instance.new("Script"); s.Name = "Big"; s.Source = string.rep("-- line\n", 6000); s.Parent = f
		local step = { n = 1, title = "t", action = "edit", targets = { "ServerStorage.RSP_TestScratch.Big" }, detail = "d", risk = "low", included = true }
		Goal.plan = { title = "p", summary = "s", verify_hint = "", steps = { step } }
		local seed = stepSeed(step)
		assert(seed:find("You are executing step 1", 1, true), "instruction present")
		assert(seed:find("page with read_script", 1, true), "cap note present")
		assert(#seed < STEP_SEED_MAX + 6000, "seed bounded, got " .. #seed)
		assert(seed:find('"n":1', 1, true) or seed:find("step 1", 1, true), "plan json present")
		Goal.plan = nil
	end)
end)
SelfTest.case("agent: afterActing routes by step statuses", function()
	Goal.plan = { steps = { { n = 1, included = true }, { n = 2, included = false } } }
	Goal.steps = { { n = 1, status = "done" }, { n = 2, status = "skipped" } }
	assert(Agent.allIncludedDone() == true, "all included done")
	Goal.steps[1].status = "failed"
	assert(Agent.allIncludedDone() == false, "failed blocks verify")
	Goal.plan, Goal.steps = nil, {}
end)
```
Reload with `DEV = true`. Expected: two FAIL lines (`stepSeed`, `Agent.allIncludedDone` nil).

- [ ] **Step 2: Step seeding and the per-step conversation**

```lua
local function stepSeed(step)
	local parts = {}
	local facts, notes = Store.readMemory()
	table.insert(parts, "=== MEMORY: FACTS ===\n" .. (facts ~= "" and facts or "(none)"))
	table.insert(parts, "=== MEMORY: NOTES ===\n" .. (notes ~= "" and notes or "(none)"))
	table.insert(parts, "=== APPROVED PLAN ===\n" .. HttpService:JSONEncode(Goal.plan))
	table.insert(parts, ("=== STEP ===\nYou are executing step %d: %s\n%s\nTargets: %s"):format(step.n, step.title, step.detail, table.concat(step.targets, ", ")))
	local budget = STEP_SEED_MAX
	for _, t in ipairs(step.targets) do
		local inst = Tools.resolve(t)
		if inst then
			local ins = Tools.read.inspect({ target = t })
			if ins.ok then
				table.insert(parts, ("=== TARGET %s (%s) ===\n%s"):format(inst:GetFullName(), Tools.ref(inst), HttpService:JSONEncode({ props = ins.props, attributes = ins.attributes, children = ins.children })))
			end
			if inst:IsA("LuaSourceContainer") and budget > 0 then
				local src = Tools.readSource(inst)
				local lines = src:split("\n")
				local numbered = {}
				for i, l in ipairs(lines) do numbered[i] = i .. "\t" .. l end
				local text = table.concat(numbered, "\n")
				if #text > budget then
					local head = utf8Trim(text, math.floor(budget * 0.75))
					local tailStart = #text - math.floor(budget * 0.25) + 1
					local b = utf8.offset(text, 0, math.min(tailStart, #text)) or tailStart
					text = head .. "\n… [middle omitted; page with read_script] …\n" .. text:sub(b)
				end
				budget -= #text
				table.insert(parts, ("=== SOURCE %s hash=%s lines=%d ===\n%s"):format(inst:GetFullName(), Store.hash(src), #lines, text))
			end
		else
			table.insert(parts, "=== TARGET " .. t .. " did not resolve; use index/search to find it ===")
		end
	end
	table.insert(parts, "=== PHASE ===\nDo only this step. Read what you need, make the writes, then call finish_step with a plain outcome. If the step cannot be done as written, say why in finish_step instead of improvising.")
	return table.concat(parts, "\n\n")
end

function Agent.allIncludedDone()
	for _, s in ipairs(Goal.plan.steps) do
		if s.included then
			local b = Goal.steps[s.n]
			if not b or b.status ~= "done" then return false end
		end
	end
	return true
end

-- One step, one conversation. Returns status, outcome.
function Agent.runStep(step)
	local b = Goal.steps[step.n] or { n = step.n, changed = {}, writes = {}, undoLabels = {} }
	Goal.steps[step.n] = b
	b.status, b.outcome = "running", nil
	GoalUI.setPhase("ACTING", ("step %d/%d"):format(step.n, #Goal.plan.steps))
	local convo = { messages = { { role = "system", content = SYS_GOAL }, { role = "user", content = stepSeed(step) } } }
	local ps = newPhaseState("ACTING", budgetFor(S.get("goal_effort", "normal")).act)
	ps.step = step
	local outcome
	local ok, why = runPhaseLoop(convo, ps, Schemas.forPhase("ACTING"), "finish_step", function(args)
		outcome = utf8Trim(tostring(args.outcome or ""), 400)
		return true
	end)
	Goal.estTokens += ps.used.tokens
	if not Agent.checkGen(ps.myGen) then b.status = "stopped"; b.outcome = "stopped"; return "stopped", "stopped" end
	if ok then
		b.status, b.outcome = "done", outcome
		GoalUI.log(("Step %d · %s · done%s"):format(step.n, step.title, #b.undoLabels > 0 and (" (undo: " .. b.undoLabels[#b.undoLabels]:gsub("RoScript Pro: ", "") .. ")") or ""), "ok")
	else
		b.status, b.outcome = "failed", tostring(why)
		GoalUI.log(("Step %d · %s · failed: %s"):format(step.n, step.title, tostring(why)), "error")
	end
	return b.status, b.outcome
end

local function runFrom(startN)
	task.spawn(function()
		local myGen = Goal.gen
		for _, s in ipairs(Goal.plan.steps) do
			if s.n >= startN then
				if not Agent.checkGen(myGen) then return end
				if RunService:IsRunning() then
					GoalUI.log("playtest running; waiting for edit mode", "muted")
					repeat task.wait(0.5) until RunService:IsEdit() or not Agent.checkGen(myGen)
					if not Agent.checkGen(myGen) then return end
				end
				if not s.included then
					Goal.steps[s.n] = Goal.steps[s.n] or { n = s.n, status = "skipped", outcome = "unticked", changed = {}, writes = {}, undoLabels = {} }
				else
					local status = Agent.runStep(s)
					if status == "stopped" then return end
					if status == "failed" then
						for _, later in ipairs(Goal.plan.steps) do
							if later.n > s.n and not Goal.steps[later.n] then
								Goal.steps[later.n] = { n = later.n, status = "skipped", outcome = ("not run: step %d failed"):format(s.n), changed = {}, writes = {}, undoLabels = {} }
							end
						end
						GoalUI.showCard("failure", { step = s })
						return -- Retry/Continue/Stop decide what happens next
					end
				end
			end
		end
		Agent.afterActing()
	end)
end

function Agent.approve()
	if Goal.phase ~= "AWAITING_APPROVAL" or not Goal.plan then return end
	Goal.gen += 1
	Goal.phase = "ACTING"
	Goal.planId = Store.nextPlanId(Goal.plan.title)
	Goal.steps = {}
	GoalUI.setBusy(true)
	runFrom(1)
end

function Agent.retryStep(n)
	if Goal.phase ~= "ACTING" then return end
	local step = Goal.plan.steps[n]
	local prev = Goal.steps[n] and Goal.steps[n].outcome or ""
	step.detail = step.detail .. "\n[previous attempt failed: " .. prev .. "]"
	for k = n, #Goal.plan.steps do if Goal.steps[k] and Goal.steps[k].status == "skipped" and Goal.steps[k].outcome:find("not run", 1, true) then Goal.steps[k] = nil end end
	Goal.gen += 1
	runFrom(n)
end

function Agent.continueFrom(n)
	if Goal.phase ~= "ACTING" then return end
	Goal.steps[n].status, Goal.steps[n].outcome = "skipped", "skipped by Jasper after failure"
	for k = n + 1, #Goal.plan.steps do if Goal.steps[k] and Goal.steps[k].outcome and Goal.steps[k].outcome:find("not run", 1, true) then Goal.steps[k] = nil end end
	Goal.gen += 1
	runFrom(n + 1)
end

function Agent.afterActing()
	if S.get("goal_verify_enabled", true) and Agent.allIncludedDone() and Agent.startVerify then
		Goal.phase = "VERIFYING"
		Agent.startVerify() -- Task 10
	else
		Goal.phase = "RECORDING"
		local anyDone, anyBad = false, false
		for _, b in pairs(Goal.steps) do
			if b.status == "done" then anyDone = true end
			if b.status == "failed" or b.status == "stopped" then anyBad = true end
		end
		Agent.record(anyBad and (anyDone and "partial" or "failed") or "done")
	end
end
```
`Agent.stop()` from Task 6 already handles ACTING: it bumps `Goal.gen` (the running batch cancels its own recording at its next check, the loop exits on `checkGen`) and routes to RECORDING with `status="stopped"`. Update `Agent.stop` so that when `Goal.phase == "ACTING"` it first marks the running step: `for _, b in pairs(Goal.steps) do if b.status == "running" then b.status, b.outcome = "stopped", "stopped" end end`.

- [ ] **Step 3: Act log batch View and the failure card (section 11)**

Extend `GoalUI.log` calls from the Executor: after a committed batch, call `GoalUI.log(("Step %d · %s · %s"):format(step.n, w.name, r.path or ""), "muted")` per write inside `Executor.runWriteBatch` (add after `results[w.index] = r` when `r.ok`). Add a `View` affordance: `GoalUI.logBatch(step, writes, results)` creates a row with a button that opens `GoalUI.prompt("batch", { title = "Step n writes", text = <per-write description> })`. Implementation:
```lua
GoalUI.logBatch = function(step, writes, results)
	local logCard = goalScroll:FindFirstChild("ActLog") or card("Act log")
	logCard.Name = "ActLog"
	local row = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = #logCard:GetChildren() }, logCard)
	mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -50, 1, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("Step %d · %d write%s"):format(step.n, #writes, #writes == 1 and "" or "s") }, row)
	button("View", row, UDim2.new(0, 44, 0, 16), UDim2.new(1, -46, 0, 1), function()
		local lines = {}
		for _, w in ipairs(writes) do
			local r = results[w.index] or {}
			local a = table.clone(w.args)
			if a.source then a.source = utf8Trim(a.source, 3000) end
			if a.newText then a.newText = utf8Trim(a.newText, 3000) end
			table.insert(lines, ("%s → %s\n%s"):format(w.name, r.ok and "ok" or ("FAILED: " .. tostring(r.error)), HttpService:JSONEncode(a)))
		end
		GoalUI.prompt("batch", { title = ("Step %d writes"):format(step.n), text = table.concat(lines, "\n\n") })
	end)
end
```
Call it at the end of `Executor.runWriteBatch` before returning (both branches). The failure card:
```lua
local function showFailureCard(step)
	local f = card(("Step %d failed"):format(step.n)); f.Name = "FailureCard"
	label(f, Goal.steps[step.n].outcome or "", C.ERR, 1)
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 2 }, f)
	button("Retry step", bar, UDim2.new(0, 90, 1, 0), UDim2.new(0, 0, 0, 0), function() f:Destroy(); Agent.retryStep(step.n) end)
	button("Continue from next", bar, UDim2.new(0, 130, 1, 0), UDim2.new(0, 96, 0, 0), function() f:Destroy(); Agent.continueFrom(step.n) end)
	button("Stop", bar, UDim2.new(0, 60, 1, 0), UDim2.new(0, 232, 0, 0), function() f:Destroy(); Agent.stop() end)
end
```
and in `GoalUI.showCard`: `elseif kind == "failure" then showFailureCard(data.step)`.

- [ ] **Step 4: Reload and verify**

Expected: the two new `agent:` cases PASS. Studio check in a scratch place: create `ServerScriptService.Shop` with a 20-line script containing a deliberate `prnt("x")` typo. Goal: "Fix the typo in Shop". Plan, Approve. Expected: act log shows `Step 1 · replace_lines ServerScriptService.Shop` (or edit_script) then `Step 1 · … · done (undo: Step 1)`; the script now reads `print`; Ctrl+Z reverts it; Ctrl+Y restores. Then a goal whose plan targets `Workspace.Baseplate` but tell it in Revise to "also rename ServerScriptService.Shop" → the off-target prompt appears; Skip → step still finishes. Press Stop mid-step on a longer plan → phase returns to idle via the RECORDING stub, no recording left open (Ctrl+Z label list has no dangling entry).

- [ ] **Step 5: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: ACTING phase with per-step conversations, act log, Retry/Continue, Stop semantics"
```

---

### Task 9: RECORDING, result card, Plans view, Revert, Trash view — the cut line

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` sections `10. AGENT` (replace the `Agent.record` stub), `11. GOAL UI` (result card, Plans view, Trash view), `8. STORE` (Facts generator helper).

**Interfaces:**
- Consumes: `Store.*`, `Goal.*`, `Schemas.forPhase("RECORDING")`, `requestWithWaits`, `runPhaseLoop`, `Tools.resolve/readSource/writeSource/hashOf`, `ChangeHistoryService.OnUndo/OnRedo`.
- Produces:
  - `Agent.record(status: string)` — builds the record, one `write_memory` turn, one `RoScript Pro: record` recording, caps, result card, `Goal.phase = "IDLE"`
  - `buildFacts() -> string` (≤ `FACTS_MAX`)
  - `Agent.revertPlan(id) -> ok, report: {restored = {}, skipped = {}}`
  - `GoalUI.showCard("result", record)`, `GoalUI.refreshPlans()`, Plans view (`showPlansView()`), Trash view (`showTrashView()`)

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("record: buildFacts is bounded and lists services", function()
	local f = buildFacts()
	assert(#f <= FACTS_MAX, "facts within cap: " .. #f)
	assert(f:find("Workspace", 1, true) and f:find("ServerScriptService", 1, true), "services listed")
end)
SelfTest.case("record: status derivation", function()
	assert(deriveStatus({ { status = "done" }, { status = "skipped" } }) == "done", "done")
	assert(deriveStatus({ { status = "done" }, { status = "failed" } }) == "partial", "partial")
	assert(deriveStatus({ { status = "failed" } }) == "failed", "failed")
end)
SelfTest.case("record: revert restores untouched scripts and skips edited ones", function()
	withScratch(function(f)
		local a = Instance.new("Script"); a.Name = "A"; a.Source = "print('after A')"; a.Parent = f
		local b = Instance.new("Script"); b.Name = "B"; b.Source = "print('after B, then hand edit')"; b.Parent = f
		local root = assert(Store.ensure())
		local rec = { v = 1, id = "Plan_900_revert-test", status = "done", createdAt = os.time(), goal = "g", summary = "s", steps = {
			{ n = 1, status = "done", changed = {
				{ path = a:GetFullName(), kind = "script", hashBefore = Store.hash("print('before A')"), hashAfter = Store.hash(a.Source), before = "before/1" },
				{ path = b:GetFullName(), kind = "script", hashBefore = Store.hash("print('before B')"), hashAfter = Store.hash("print('after B')"), before = "before/2" },
			} } } }
		assert(Store.withRecording("test", function() Store.writePlan(rec, { [1] = "print('before A')", [2] = "print('before B')" }) end))
		local ok, report = Agent.revertPlan("Plan_900_revert-test")
		assert(ok and #report.restored == 1 and #report.skipped == 1, ("restored %d skipped %d"):format(#report.restored, #report.skipped))
		assert(a.Source == "print('before A')" and b.Source:find("hand edit", 1, true), "A reverted, B skipped")
		root.Plans.Plan_900_revert-test:Destroy()
	end)
end)
```
Reload with `DEV = true`. Expected: three FAIL lines. (Run in a place without a real store, or accept the test record being pruned later.)

- [ ] **Step 2: Facts, status, the record turn**

```lua
local function buildFacts()
	local lines = { "Top-level services and child counts:" }
	for _, svc in ipairs({ "Workspace", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService" }) do
		local okS, s = pcall(game.GetService, game, svc)
		if okS and s then table.insert(lines, ("- %s: %d children"):format(svc, #s:GetChildren())) end
	end
	local manifest = Store.readManifest()
	local seen, edited = {}, {}
	for _, p in ipairs((Store.root() and Store.root().Plans:GetChildren()) or {}) do
		local rec = Store.readPlan(p.Name)
		for _, st in ipairs(rec and rec.steps or {}) do
			for _, ch in ipairs(st.changed or {}) do if ch.kind == "script" then seen[ch.path] = ch.hashAfter end end
		end
	end
	table.insert(lines, "Scripts changed by past plans (path: hash now):")
	for path, h in pairs(seen) do
		local inst = walkPath(path)
		local now = inst and inst:IsA("LuaSourceContainer") and Tools.hashOf(inst) or "missing"
		table.insert(lines, ("- %s: %s%s"):format(path, now, (manifest[path] and manifest[path] ~= now) and " (edited outside Goal Mode)" or ""))
	end
	for path, h in pairs(manifest) do
		local inst = walkPath(path)
		if inst and inst:IsA("LuaSourceContainer") and Tools.hashOf(inst) ~= h and not seen[path] then table.insert(edited, path) end
	end
	if #edited > 0 then table.insert(lines, "Scripts edited by hand since the last record: " .. table.concat(edited, ", ")) end
	table.insert(lines, ("Trash items: %d"):format(#Store.trashItems()))
	local page = Store.listPlans(0)
	local ids = {}
	for i = 1, math.min(3, #page) do table.insert(ids, page[i].id .. " (" .. page[i].status .. ")") end
	table.insert(lines, "Recent plans: " .. (#ids > 0 and table.concat(ids, ", ") or "none"))
	return utf8Trim(table.concat(lines, "\n"), FACTS_MAX)
end

local function deriveStatus(steps)
	local anyDone, anyBad = false, false
	for _, b in pairs(steps) do
		if b.status == "done" then anyDone = true end
		if b.status == "failed" or b.status == "stopped" then anyBad = true end
	end
	if not anyBad then return "done" end
	return anyDone and "partial" or "failed"
end

local function buildManifest()
	local map = {}
	for _, inst in ipairs(game:GetDescendants()) do
		if inst:IsA("LuaSourceContainer") and not (Store.root() and inst:IsDescendantOf(Store.root())) then
			map[inst:GetFullName()] = Tools.hashOf(inst)
		end
	end
	return map
end

function Agent.record(status)
	Goal.phase = "RECORDING"
	GoalUI.setPhase("RECORDING", "writing memory")
	local myGen = Goal.gen
	task.spawn(function()
		repeat task.wait(0.25) until Store.inEdit() or not Agent.checkGen(myGen)
		if not Agent.checkGen(myGen) then return end
		local steps = {}
		for n, b in pairs(Goal.steps) do
			steps[#steps + 1] = { n = n, status = b.status, outcome = b.outcome, changed = b.changed, writes = b.writes, undoLabels = b.undoLabels }
		end
		table.sort(steps, function(x, y) return x.n < y.n end)
		local record = {
			v = 1, id = Goal.planId or Store.nextPlanId(Goal.plan and Goal.plan.title or "plan"),
			status = status or deriveStatus(Goal.steps), createdAt = os.time(),
			goal = Goal.goalText, focus = S.get("goal_focus", { bugs = true, quality = true }),
			plan = Goal.plan, revisions = Goal.revisions, steps = steps, verify = Goal.verify,
			models = Goal.models, estTokens = Goal.estTokens, summary = Goal.plan and Goal.plan.summary or "",
		}
		-- trim writes[] per step to WRITES_MAX_CHARS
		for _, st in ipairs(record.steps) do
			while #HttpService:JSONEncode(st.writes or {}) > WRITES_MAX_CHARS and #st.writes > 0 do
				local w = st.writes[#st.writes]
				if w.replace and #w.replace > 40 then w.replace = utf8Trim(w.replace, 40) elseif w.find and #w.find > 40 then w.find = utf8Trim(w.find, 40) else table.remove(st.writes) end
			end
		end
		local facts = buildFacts()
		local _, oldNotes = Store.readMemory()
		local newNotes, summary = oldNotes, record.summary
		if status ~= "cancelled" and Goal.plan then
			local convo = { messages = { { role = "system", content = SYS_GOAL }, { role = "user", content = ("=== MEMORY: FACTS ===\n%s\n\n=== MEMORY: NOTES (current) ===\n%s\n\n=== RECORD ===\n%s\n\n=== PHASE ===\nRewrite Notes (≤ %d chars, keep the headings Game / Conventions / Decisions / Known issues) and give a ≤ %d-char summary of this plan. Call write_memory once."):format(facts, oldNotes ~= "" and oldNotes or "(none)", HttpService:JSONEncode(record), NOTES_MAX, SUMMARY_MAX) } } }
			local ps = newPhaseState("RECORDING", 1)
			ps.budget.calls = 1
			runPhaseLoop(convo, ps, Schemas.forPhase("RECORDING"), "write_memory", function(args)
				newNotes = utf8Trim(tostring(args.notes or oldNotes), NOTES_MAX)
				summary = utf8Trim(tostring(args.plan_summary or summary), SUMMARY_MAX)
				return true
			end)
			Goal.estTokens += ps.used.tokens
			record.estTokens = Goal.estTokens
			if not Agent.checkGen(myGen) then return end
		end
		record.summary = summary
		local beforeSources = {}
		for n, b in pairs(Goal.steps) do
			for k, src in pairs(b.beforeSources or {}) do beforeSources[#beforeSources + 1] = src end
		end
		-- re-key changed[].before to the flattened numbering
		local k = 0
		for _, st in ipairs(record.steps) do
			for _, ch in ipairs(st.changed or {}) do if ch.before then k += 1; ch.before = "before/" .. k end end
		end
		local ok, err = Store.withRecording("record", function()
			Store.writeMemory(facts, newNotes)
			Store.writeManifest(buildManifest())
			Store.writePlan(record, beforeSources)
			Store.applyCaps()
		end)
		if not ok then GoalUI.log("record not written: " .. tostring(err), "error") end
		Goal.phase = "IDLE"
		GoalUI.setBusy(false)
		GoalUI.setPhase("IDLE", record.id .. " · " .. record.status)
		GoalUI.showCard("result", record)
		GoalUI.refreshPlans()
	end)
end
```
The `beforeSources` flattening assumes each step's `changed[].before` were numbered per step in Task 7 (`"before/" .. k` with `k` local to the step); the re-key loop above renumbers them globally in step order, matching the order the sources are appended. Iterate `Goal.steps` in ascending `n` in both loops (use the sorted `steps` array's `n` values, not `pairs`).

- [ ] **Step 3: Revert**

```lua
function Agent.revertPlan(id)
	local rec, err = Store.readPlan(id)
	if not rec then return false, { error = err } end
	local report = { restored = {}, skipped = {} }
	local root = Store.root()
	local folder = root and root.Plans:FindFirstChild(id)
	local ok, werr = Store.withRecording("revert " .. id, function()
		for i = #rec.steps, 1, -1 do
			local st = rec.steps[i]
			for j = #(st.changed or {}), 1, -1 do
				local ch = st.changed[j]
				local inst = walkPath(ch.path)
				if ch.kind == "script" and ch.before then
					local beforeFolder = folder and folder:FindFirstChild("before") and folder.before:FindFirstChild(ch.before:match("before/(.+)"))
					if inst and inst:IsA("LuaSourceContainer") and beforeFolder then
						if Tools.hashOf(inst) == ch.hashAfter then
							local src = Store.readText(beforeFolder)
							assert(Tools.writeSource(inst, function() return src end))
							table.insert(report.restored, ch.path)
						else
							table.insert(report.skipped, ch.path .. " (edited since)")
						end
					else
						table.insert(report.skipped, ch.path .. " (missing)")
					end
				elseif ch.created and inst then
					Store.trash(inst, id .. "-revert"); table.insert(report.restored, ch.path .. " (trashed)")
				elseif (ch.trashed or ch.origParent) then
					local item = nil
					for _, it in ipairs(Store.trashItems()) do if it:GetAttribute("RSP_OrigName") == ch.path:match("([^.]+)$") and it:GetAttribute("RSP_Plan") == id then item = it end end
					local target = item or inst
					local parent = ch.origParent and walkPath(ch.origParent)
					if target and parent then target.Parent = parent; table.insert(report.restored, ch.path) else table.insert(report.skipped, ch.path .. " (origin missing)") end
				end
			end
		end
	end)
	if not ok then return false, { error = werr } end
	return true, report
end
```

- [ ] **Step 4: Result card, Plans view, Trash view (section 11)**

```lua
local function showResultCard(rec)
	local f = card(("%s · %s"):format(rec.id, rec.status)); f.Name = "ResultCard"
	local done, total = 0, 0
	for _, st in ipairs(rec.steps or {}) do total += 1; if st.status == "done" then done += 1 end end
	local v = rec.verify
	local vtext = v and v.ran and ("Run: %d errors, %d warnings%s%s"):format(#(v.errors or {}), v.warnings or 0, (#(v.preexisting or {}) > 0) and (" (" .. #v.preexisting .. " pre-existing)") or "", (v.repair and v.repair.ran) and " · repaired" or "") or (v and v.overflowed and "Run: capture truncated, inconclusive" or "no verify run")
	label(f, ("%d/%d steps done · %s"):format(done, total, vtext), C.TEXT, 1)
	label(f, rec.summary or "", C.MUTED, 2)
	label(f, "Ctrl+Z removes this record first, then the last step.", C.MUTED, 3)
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 4 }, f)
	button("Plan next", bar, UDim2.new(0, 80, 1, 0), UDim2.new(0, 0, 0, 0), function()
		for _, c in ipairs(goalScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
		Agent.plan("")
	end)
	button("Revert plan", bar, UDim2.new(0, 90, 1, 0), UDim2.new(0, 86, 0, 0), function()
		if GoalUI.prompt("confirm", { title = "Revert " .. rec.id .. "?", text = "Restores every changed script whose current hash still matches the record, moves created instances to Trash, and puts moved/trashed instances back. Files edited since are skipped and listed." }) == "allow" then
			local ok, report = Agent.revertPlan(rec.id)
			GoalUI.log(ok and ("reverted %d, skipped %d: %s"):format(#report.restored, #report.skipped, table.concat(report.skipped, "; ")) or ("revert failed: " .. tostring(report.error)), ok and "ok" or "error")
		end
	end)
	button("View record", bar, UDim2.new(0, 90, 1, 0), UDim2.new(0, 182, 0, 0), function()
		GoalUI.prompt("record", { title = rec.id, text = rec.summary .. "\n\n" .. HttpService:JSONEncode(rec) })
	end)
end

local function showPlansView(offset)
	for _, c in ipairs(goalScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
	local page, total = Store.listPlans(offset)
	local f = card(("Plans %d–%d of %d"):format(offset + 1, offset + #page, total)); f.Name = "PlansView"
	for i, p in ipairs(page) do
		local row = mk("Frame", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = i }, f)
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -150, 1, 0), Position = UDim2.new(0, 6, 0, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("%s · %s · %s"):format(p.id, p.status, p.goal) }, row)
		button("Open", row, UDim2.new(0, 44, 0, 18), UDim2.new(1, -140, 0, 2), function()
			local rec = Store.readPlan(p.id)
			GoalUI.prompt("record", { title = p.id, text = rec and (rec.summary .. "\n\n" .. HttpService:JSONEncode(rec)) or "unreadable record" })
		end)
		button("Revert", row, UDim2.new(0, 50, 0, 18), UDim2.new(1, -90, 0, 2), function()
			if GoalUI.prompt("confirm", { title = "Revert " .. p.id .. "?", text = "See result card note." }) == "allow" then
				local ok, report = Agent.revertPlan(p.id)
				GoalUI.log(ok and ("reverted %d, skipped %d"):format(#report.restored, #report.skipped) or ("revert failed: " .. tostring(report.error)), ok and "ok" or "error")
			end
		end)
	end
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 99 }, f)
	if offset > 0 then button("Newer", bar, UDim2.new(0, 60, 1, 0), UDim2.new(0, 0, 0, 0), function() showPlansView(math.max(0, offset - 10)) end) end
	if offset + #page < total then button("Older", bar, UDim2.new(0, 60, 1, 0), UDim2.new(0, 66, 0, 0), function() showPlansView(offset + 10) end) end
	button("Back", bar, UDim2.new(0, 60, 1, 0), UDim2.new(1, -60, 0, 0), function() f:Destroy() end)
end

local function showTrashView()
	for _, c in ipairs(goalScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
	local items = Store.trashItems()
	local f = card(("Trash (%d)"):format(#items)); f.Name = "TrashView"
	for i, it in ipairs(items) do
		local row = mk("Frame", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = i }, f)
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -70, 1, 0), Position = UDim2.new(0, 6, 0, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("%s ← %s"):format(it.Name, it:GetAttribute("RSP_OrigParent") or "?") }, row)
		button("Restore", row, UDim2.new(0, 60, 0, 18), UDim2.new(1, -64, 0, 2), function()
			local ok, err = Store.restore(it, nil)
			if not ok and tostring(err):find("conflict", 1, true) then
				local a = GoalUI.prompt("confirm", { title = "Name conflict", text = tostring(err) .. "\n\nAllow = rename with _restored, Skip = replace the existing one." })
				if a == "allow" then Store.restore(it, "rename") elseif a == "skip" then Store.restore(it, "replace") end
			end
			showTrashView()
		end)
	end
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 99 }, f)
	if #items > 0 then
		button("Empty Trash", bar, UDim2.new(0, 90, 1, 0), UDim2.new(0, 0, 0, 0), function()
			if GoalUI.prompt("confirm", { title = "Empty Trash?", text = ("Destroys %d items permanently. Undo works until you close Studio."):format(#items) }) == "allow" then Store.emptyTrash(); showTrashView() end
		end)
	end
	button("Back", bar, UDim2.new(0, 60, 1, 0), UDim2.new(1, -60, 0, 0), function() f:Destroy() end)
end

GoalUI.refreshPlans = function()
	if goalScroll and goalScroll:FindFirstChild("PlansView") then showPlansView(0) end
	local _, total = Store.listPlans(0)
	local bytes = 0
	local root = Store.root()
	if root then
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("StringValue") then bytes += #d.Value end
		end
	end
	if plansButton then plansButton.Text = ("Plans (%d, ~%dkB)"):format(total, math.ceil(bytes / 1024)) end
	if trashButton then trashButton.Text = ("Trash (%d)"):format(#Store.trashItems()) end
end
```
Extend `GoalUI.showCard` with `elseif kind == "result" then showResultCard(data)`. In `buildGoalView`, add two buttons to the button row: `plansButton = button("Plans", row, UDim2.new(0, 70, 1, 0), UDim2.new(1, -150, 0, 0), function() showPlansView(0) end)` and `trashButton = button("Trash", row, UDim2.new(0, 70, 1, 0), UDim2.new(1, -74, 0, 0), showTrashView)`; shrink `phaseLabel` to `Size = UDim2.new(1, -320, 1, 0)`. Declare `plansButton, trashButton` with the other section-11 locals. In BOOTSTRAP, after `buildUI(w)`, connect `ChangeHistoryService.OnUndo:Connect(GoalUI.refreshPlans)` and `ChangeHistoryService.OnRedo:Connect(GoalUI.refreshPlans)` and call `GoalUI.refreshPlans()` once.

- [ ] **Step 5: Reload and verify**

Expected: the three `record:` cases PASS. Studio check: run the Task 8 typo goal end-to-end. Expected: result card `Plan_001_… · done · 1/1 steps done · no verify run` (verify not built yet), `ServerStorage.RoScriptPro.Plans.Plan_001_…` with chunks and a `before/1`, Memory has Facts and Notes, Manifest is non-empty. Ctrl+Z once: the record folder disappears and the Plans button count drops; Ctrl+Z again: the typo is back; Ctrl+Y twice restores both. Plan next with an empty box proposes improvements that mention `Shop`. Revert plan on the record restores the typo (hash matched) and says so in the act log. Trash view lists nothing; trash a Model in a later goal and Restore brings it back.

- [ ] **Step 6: Commit (the cut line)**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: RECORDING (facts, notes, manifest, one-recording record), result card, Plans view, Revert, Trash view"
```
Everything from here is behind the verify setting. If Jasper wants to ship now, this is the state to PR.

---

### Task 10: VERIFYING and REPAIRING (Run-button driven)

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` sections `10. AGENT` (verify + repair), `11. GOAL UI` (verify card).

**Interfaces:**
- Consumes: `LogService.MessageOut`, `LogService:GetLogHistory()`, `RunService.Heartbeat/IsRunning/IsEdit`, Task 8 (`Agent.afterActing` calls `Agent.startVerify`), Task 9 (`Agent.record`), `runPhaseLoop`, `Schemas.forPhase("REPAIRING")`.
- Produces:
  - `Agent.startVerify()` — shows the verify card, arms capture, polls for the run, finalises into `Goal.verify`
  - `Agent.skipVerify()`
  - `captureFromHistory(boundaryTs) -> errors, warnings, output, overflowed`
  - `attributeErrors(errors, changedPaths) -> triggering, preexisting`
  - `Agent.repair()` — REPAIRING phase, then a second verify card for the confirm run
  - `Goal.verify = { enabled, ran, overflowed, errors, preexisting, warnings, output, repair = { ran, outcome, changed, undoLabels, errorsAfter } }`
  - `GoalUI.showCard("verify", { second: boolean })`
- Invariant: this task adds **no** call to `RunService:Run()` or `RunService:Stop()`.

- [ ] **Step 1: Write the failing self-tests**

```lua
SelfTest.case("verify: history capture honours the boundary and the ring", function()
	local fake = {}
	for i = 1, 600 do fake[i] = { message = "old " .. i, messageType = Enum.MessageType.MessageOutput, timestamp = 1000 + i } end
	local errs, warns, out, overflowed = captureFromHistoryTable(fake, 1700)
	assert(#errs == 0 and overflowed == false, "nothing after boundary")
	table.insert(fake, { message = "ServerScriptService.Shop:12: attempt to index nil", messageType = Enum.MessageType.MessageError, timestamp = 1700 })
	table.insert(fake, { message = "careful", messageType = Enum.MessageType.MessageWarning, timestamp = 1701 })
	errs, warns, out, overflowed = captureFromHistoryTable(fake, 1700)
	assert(#errs == 1 and warns == 1, ("errors %d warnings %d"):format(#errs, warns))
	local ring = {}
	for i = 1, 512 do ring[i] = { message = "e" .. i, messageType = Enum.MessageType.MessageError, timestamp = 2000 + i } end
	local _, _, _, ov = captureFromHistoryTable(ring, 1999)
	assert(ov == true, "all 512 entries newer than the boundary means overflow")
end)
SelfTest.case("verify: error attribution by changed script path", function()
	local trig, pre = attributeErrors({ "ServerScriptService.Shop:12: attempt to index nil", "Workspace.Old.Script:3: boom", "Stack Begin" }, { ["ServerScriptService.Shop"] = true })
	assert(#trig == 1 and #pre == 2, ("trig %d pre %d"):format(#trig, #pre))
end)
```
Reload with `DEV = true`. Expected: two FAIL lines.

- [ ] **Step 2: Capture helpers**

```lua
-- Pure: works on any history-shaped table so it can be tested without a run.
local function captureFromHistoryTable(hist, boundaryTs)
	local errors, output, warnings, chars = {}, {}, 0, 0
	local sawOlder = false
	for i = #hist, 1, -1 do
		local e = hist[i]
		if (e.timestamp or 0) < boundaryTs - 1 then sawOlder = true; break end
		local msg = tostring(e.message)
		if e.messageType == Enum.MessageType.MessageError then
			if chars + #msg <= OUTPUT_MAX_CHARS then table.insert(errors, 1, msg); chars += #msg end
		elseif e.messageType == Enum.MessageType.MessageWarning then
			warnings += 1
			if chars + #msg <= OUTPUT_MAX_CHARS then table.insert(errors, 1, "[warn] " .. msg); chars += #msg end
		elseif #output < 60 then
			table.insert(output, 1, utf8Trim(msg, 200))
		end
	end
	local overflowed = (#hist >= 512) and not sawOlder
	return errors, warnings, output, overflowed
end
local function captureFromHistory(boundaryTs)
	return captureFromHistoryTable(LogService:GetLogHistory(), boundaryTs)
end

local function attributeErrors(errors, changedPaths)
	local trig, pre = {}, {}
	for _, e in ipairs(errors) do
		local hit = false
		for path in pairs(changedPaths) do
			if e:find(path, 1, true) then hit = true; break end
		end
		table.insert(hit and trig or pre, e)
	end
	return trig, pre
end
```

- [ ] **Step 3: The verify flow**

```lua
local function changedPathSet()
	local set = {}
	for _, b in pairs(Goal.steps) do
		for _, ch in ipairs(b.changed or {}) do if ch.kind == "script" then set[ch.path] = true end end
	end
	return set
end

function Agent.skipVerify()
	if Goal.phase ~= "VERIFYING" then return end
	if Goal.verifyConn then Goal.verifyConn:Disconnect(); Goal.verifyConn = nil end
	if Goal.verifyHb then Goal.verifyHb:Disconnect(); Goal.verifyHb = nil end
	Goal.verify = Goal.verify or { enabled = true }
	Goal.verify.ran = false
	Goal.phase = "RECORDING"
	Agent.record(deriveStatus(Goal.steps))
end

-- second = true for the confirm run after a repair pass.
local function armVerify(second)
	local myGen = Goal.gen
	Goal.verify = Goal.verify or { enabled = true, ran = false, errors = {}, preexisting = {}, warnings = 0, output = {} }
	local live = {}
	local hist = LogService:GetLogHistory()
	local boundary = #hist > 0 and (hist[#hist].timestamp or os.time()) or os.time()
	Goal.verifyConn = LogService.MessageOut:Connect(function(msg, mtype)
		if mtype == Enum.MessageType.MessageError or mtype == Enum.MessageType.MessageWarning then
			table.insert(live, { message = msg, messageType = mtype, timestamp = os.time() })
			GoalUI.setPhase("VERIFYING", ("%d error/warning lines so far"):format(#live))
		end
	end)
	GoalUI.showCard("verify", { second = second })
	local wasRunning, started = false, os.clock()
	Goal.verifyHb = RunService.Heartbeat:Connect(function()
		if not Agent.checkGen(myGen) then
			Goal.verifyHb:Disconnect(); Goal.verifyHb = nil
			if Goal.verifyConn then Goal.verifyConn:Disconnect(); Goal.verifyConn = nil end
			return
		end
		if RunService:IsRunning() then
			wasRunning = true
		elseif wasRunning and RunService:IsEdit() then
			Goal.verifyHb:Disconnect(); Goal.verifyHb = nil
			Goal.verifyConn:Disconnect(); Goal.verifyConn = nil
			-- Primary = MessageOut; fallback = history diff (S2). Merge: history fills output lines and covers a MessageOut miss.
			local hErrors, hWarnings, hOutput, overflowed = captureFromHistory(boundary)
			local errors = {}
			for _, l in ipairs(live) do table.insert(errors, (l.messageType == Enum.MessageType.MessageWarning and "[warn] " or "") .. l.message) end
			if #errors == 0 then errors = hErrors end
			local v = Goal.verify
			v.ran, v.overflowed, v.output = true, overflowed, hOutput
			local trig, pre = attributeErrors(errors, changedPathSet())
			if second then
				v.repair = v.repair or {}
				v.repair.errorsAfter = trig
				v.repair.ran = true
				Goal.phase = "RECORDING"
				Agent.record(deriveStatus(Goal.steps))
				return
			end
			v.errors, v.preexisting, v.warnings = trig, pre, hWarnings
			if overflowed then
				GoalUI.log("capture truncated (512-entry ring), result inconclusive; no repair", "error")
				Goal.phase = "RECORDING"; Agent.record(deriveStatus(Goal.steps)); return
			end
			if #trig > 0 then
				Agent.repair()
			else
				GoalUI.log(("verify: 0 errors on changed scripts%s"):format(#pre > 0 and (", " .. #pre .. " pre-existing") or ""), "ok")
				Goal.phase = "RECORDING"; Agent.record(deriveStatus(Goal.steps))
			end
		end
	end)
end

function Agent.startVerify()
	Goal.phase = "VERIFYING"
	GoalUI.setPhase("VERIFYING", "press Run (F8), then Stop")
	armVerify(false)
end

function Agent.repair()
	Goal.phase = "REPAIRING"
	GoalUI.setPhase("REPAIRING", "fixing errors on changed scripts")
	local myGen = Goal.gen
	task.spawn(function()
		local b = budgetFor(S.get("goal_effort", "normal"))
		local v = Goal.verify
		v.repair = { ran = true, outcome = nil, changed = {}, undoLabels = {}, errorsAfter = {} }
		local changed = {}
		for path in pairs(changedPathSet()) do table.insert(changed, path) end
		local step = { n = 0, title = "Repair", action = "edit", targets = changed, detail = "fix only what these errors point at; do not extend the plan", risk = "medium", included = true }
		Goal.steps[0] = { n = 0, changed = {}, writes = {}, undoLabels = {} }
		local seed = ("=== ERRORS ON CHANGED SCRIPTS ===\n%s\n\n=== VERIFY HINT ===\n%s\n\n=== CHANGED SCRIPTS ===\n%s\n\n=== PHASE ===\nFix only what these errors point at; do not extend the plan. Read the failing lines first. Call finish_step when done."):format(table.concat(v.errors, "\n"), Goal.plan.verify_hint or "", table.concat(changed, "\n"))
		local convo = { messages = { { role = "system", content = SYS_GOAL }, { role = "user", content = stepSeed(step) .. "\n\n" .. seed } } }
		local ps = newPhaseState("REPAIRING", b.repair)
		ps.step = step
		local ok, why = runPhaseLoop(convo, ps, Schemas.forPhase("REPAIRING"), "finish_step", function(args)
			v.repair.outcome = utf8Trim(tostring(args.outcome or ""), 400)
			return true
		end)
		Goal.estTokens += ps.used.tokens
		if not Agent.checkGen(myGen) then return end
		v.repair.changed, v.repair.undoLabels = Goal.steps[0].changed, Goal.steps[0].undoLabels
		Goal.steps[0] = nil
		if not ok then v.repair.outcome = "repair failed: " .. tostring(why) end
		-- Executor labels batches "Step 0"; relabel the recording names for repair
		for i, l in ipairs(v.repair.undoLabels) do v.repair.undoLabels[i] = l:gsub("Step 0", "Repair") end
		Goal.phase = "VERIFYING"
		GoalUI.setPhase("VERIFYING", "press Run again to confirm, then Stop")
		armVerify(true)
	end)
end
```
In `Executor.runWriteBatch` the label builder uses `step.n`; add `local label = step.n == 0 and "Repair" or ("Step %d"):format(step.n)` so repair recordings read `RoScript Pro: Repair, part k` directly (then drop the `gsub` relabel above).

- [ ] **Step 4: Verify card (section 11)**

```lua
local function showVerifyCard(second)
	local old = goalScroll:FindFirstChild("VerifyCard"); if old then old:Destroy() end
	local f = card(second and "Confirm run" or "Verify"); f.Name = "VerifyCard"
	label(f, second and "Press Run (F8) again, let it run a few seconds, then Stop. The plugin records what changed after the repair." or "Press Run (F8), let it run a few seconds, then Stop. The plugin captures errors while it runs and never starts or stops the playtest itself.", C.TEXT, 1)
	label(f, "A Run executes every server Script against live services (DataStore, HTTP) exactly as any playtest does.", C.MUTED, 2)
	local status = label(f, "waiting for Run…", C.MUTED, 3); status.Name = "Status"
	local t0 = os.clock()
	local hb; hb = RunService.Heartbeat:Connect(function()
		if not f.Parent then hb:Disconnect(); return end
		if RunService:IsRunning() then status.Text = ("running · %ds"):format(math.floor(os.clock() - t0)) end
	end)
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 4 }, f)
	button("Skip", bar, UDim2.new(0, 60, 1, 0), UDim2.new(0, 0, 0, 0), function() f:Destroy(); Agent.skipVerify() end)
end
```
Extend `GoalUI.showCard` with `elseif kind == "verify" then showVerifyCard(data.second)`.

- [ ] **Step 5: Reload and verify**

Expected: the two `verify:` cases PASS. Studio check (S2/S3 passed): goal "Add a Script named Boom in ServerScriptService that errors on start with the message boom" → Approve → verify card → F8, 5 s, Stop → act log `verify: 1 error` is NOT printed; instead REPAIRING runs (the error names `ServerScriptService.Boom`), the repair edits or comments it out, the confirm card appears → F8, Stop → result card shows `Run: 1 errors … · repaired` and `verify.repair.errorsAfter` is empty in the record JSON. Add a pre-existing erroring script elsewhere first and confirm it lands in `preexisting`, not in a repair. Press Skip on a verify card → record written with `verify.ran=false`.

- [ ] **Step 6: Commit**

`DEV = false`. Show the diff; on Jasper's OK:
```bash
git add studio-plugin/RoScriptPro.lua
git commit -m "goal-mode: Run-button VERIFY with MessageOut + history capture, error attribution, one repair pass"
```

---

### Task 11: Settings group, header, checklist, review gate, PR

**Files:**
- Modify: `studio-plugin/RoScriptPro.lua` section `7. UI` (settings panel group), header comment; `README.md` (Goal Mode section); spec §2 results if not yet recorded.

**Interfaces:**
- Consumes: everything above.
- Produces: the shippable `feature/goal-mode` branch and its PR.

- [ ] **Step 1: Settings group**

In the existing settings panel builder (section 7, the function that toggles `settingsPanel.Visible`), add a "Goal Mode" group with three controls, using the same `mk` patterns the key rows use:
```lua
	local function toggleRow(y, text, key, default)
		local b = mk("TextButton", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0, y), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = "", AutoButtonColor = false }, settingsPanel)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
		local function paint() b.Text = ("  %s: %s"):format(text, S.get(key, default) and "ON" or "OFF") end
		paint()
		b.MouseButton1Click:Connect(function() S.set(key, not S.get(key, default)); paint() end)
		b.MouseEnter:Connect(function() b.BackgroundColor3 = C.ACCENT end)
		b.MouseLeave:Connect(function() b.BackgroundColor3 = C.PANEL2 end)
		return b
	end
	mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 18), Position = UDim2.new(0, 8, 0, GOAL_Y), Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = "Goal Mode" }, settingsPanel)
	toggleRow(GOAL_Y + 22, "Verify after acting (Run button)", "goal_verify_enabled", true)
	toggleRow(GOAL_Y + 48, "Careful: every write prompts", "goal_careful", false)
	local effort = mk("TextButton", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0, GOAL_Y + 74), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, Text = "", AutoButtonColor = false }, settingsPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, effort)
	local function paintEffort() effort.Text = "  Effort: " .. S.get("goal_effort", "normal") .. " (normal = 12/8/6 calls, deep = double)" end
	paintEffort()
	effort.MouseButton1Click:Connect(function() S.set("goal_effort", S.get("goal_effort", "normal") == "normal" and "deep" or "normal"); paintEffort() end)
	effort.MouseEnter:Connect(function() effort.BackgroundColor3 = C.ACCENT end)
	effort.MouseLeave:Connect(function() effort.BackgroundColor3 = C.PANEL2 end)
```
`GOAL_Y` is the y-offset below the last existing key row; read the panel's current layout and set it so nothing overlaps (increase the panel's height if needed). If S3 failed, the verify toggle's default here is `false`.

- [ ] **Step 2: Header, README, spec**

Header block: version line `v2 (Goal Mode)`, add "Goal Mode: toggle Chat|Goal in the top bar; the store lives in ServerStorage.RoScriptPro; verify uses the Run button" to the comment. `README.md`: a "Goal Mode" section (what it does, the cycle, the store, the two safety facts: never destroys, never starts a playtest). Spec §2: results column present (Task 0 Step 3).

- [ ] **Step 3: Run the spec's §15 checklist**

Walk every item of spec §15 in a scratch place and record `pass/fail + note` per item in the PR description. Any fail becomes a fix commit on the branch before review.

- [ ] **Step 4: Review gate**

Run `code-reviewer` on the full diff `main...feature/goal-mode`, then `review-loop` until it passes. Apply findings as commits (each shown, each OK'd). Specifically confirm by reading the code: no `RunService:Run(` or `RunService:Stop(` anywhere; every `TryBeginRecording` has exactly one `FinishRecording` owner; every `UpdateSourceAsync` return is followed by an `Agent.checkGen`; `Store.write*` is only reached inside a recording or `Store.withRecording`; no `:Destroy()` on user content outside `Store.emptyTrash`/`applyCaps`.

- [ ] **Step 5: Push and open the PR**

`DEV = false` confirmed. Show the final diff summary; on Jasper's OK:
```bash
git push -u origin feature/goal-mode
gh pr create --base main --head feature/goal-mode --title "Goal Mode (v2)" --body-file -
```
PR body: what it is (one paragraph), the settled decisions, the spike results, the §15 checklist results, the review gate outcome, install line (`Copy-Item "studio-plugin\RoScriptPro.lua" "$env:LOCALAPPDATA\Roblox\Plugins\"`), and the two safety facts. Jasper merges.

---

## Self-review (run after writing; results applied inline)

**Spec coverage, section by section:**
- §1 decisions: D1 Task 4–5, D2 Task 7 (§8.4 prompts), D3 Task 2, D4 Task 2/7 (`trash`, `emptyTrash`), D5 Task 10 (no `Run()`/`Stop()` calls), D6 Task 1 banners, D7 one cycle at a time (`Agent.plan` refuses unless IDLE), D8 no paid calls.
- §2 spikes: Task 0. §3 cycle: Tasks 6, 8, 9, 10 (`Agent.stop` in Task 6/8). §4 store: Task 2 (layout, chunks, memory, manifest, records, trash, restore, caps), Task 9 (Facts, one-recording RECORDING, Revert, OnUndo refresh). §5 tools: Task 3 (read), Task 7 (write, syntax gate, props pairs, multi-target, `set_props` contract), Task 5 (unknown/out-of-phase tool error, control-last rule). §6 loop: Task 5 (schemas rules, estimate, compaction, waits, pacing, budgets, batch rule, consecutive-error definition), Task 4 (transport, minimal OpenRouter body, `GOAL_MAXTOK`, 413-first, bad-tool-call retry), Task 6 (byte-stable system message, variable first user message, nudge rule, PLAN exhaustion final turn). §7 PLANNING: Task 6 (inputs incl. Selection/active script/read_output when `bugs`, validation, plan card, Revise on the kept transcript, Cancel). §8 ACTING: Task 8 (per-step seed with `STEP_SEED_MAX`, outcomes, Retry/Continue, VERIFY-only-if-all-done), Task 7 (recording rules, prompts before recording, off-target binding, risk-high rewrite exemption, act log). §9 VERIFY: Task 10. §10 RECORDING: Task 9 (record fields incl. `revisions[]`, `writes[]` cap, Plan next ignores the box, result card hint). §11 errors: Task 5/6/8 (`checkGen`, cleanup exempt, waits, unreadable records, `IsRunning` guards). §12 settings: Task 1 keys, Task 11 panel (three exposed). §13 UI: Tasks 6, 8, 9, 10. §14 layout/build order/cut line: Task 1 banners, order of Tasks 2→9, cut line at Task 9. §15 checklist: Task 11 Step 3. §16: nothing here implements a NOT-in-v2 item.
- **Gaps found and fixed inline (now in the task text):** `read_output` pre-injection when `bugs` is ticked was missing from `buildGoalUserBlock` → added in Task 6 Step 2 before the TOP-LEVEL INDEX block. Store size estimate next to `Plans` (§4.5) → `GoalUI.refreshPlans` in Task 9 Step 4 sums StringValue bytes under the root and shows `Plans (n, ~NNkB)`. Per-provider request counters in the status line (§6.4) → `GoalUI.setPhase` in Task 6 Step 4 appends `req G/C/O` from `Goal.requests`.

**Placeholder scan:** no TBD/TODO; every code step has code; the only deferred bodies are stubs explicitly replaced in a named later task (`Executor` stub in Task 5 → Task 7; `Agent.record` stub in Task 6 → Task 9).

**Type and name consistency:** `Tools.read.<name>(args)` and `Tools.write.<name>(args, ctx)` throughout; `runToolBatch(calls, ps)` returns `results, control`; `Executor.runWriteBatch(writes, ps)` returns `results, committed` with `results[index]`; `ps.step` carries `n, targets, risk`; `Goal.steps[n]` carries `status, outcome, changed, writes, undoLabels, beforeSources`; `Store.withRecording(label, fn)` returns `ok, err`; `GoalUI.prompt(kind, payload{title,text})` returns `"allow"|"skip"|"stop"`; `Agent.record(status)` ends every cycle; `budgetFor(effort)` fields `plan, revise, act, repair, repairPasses, tokens`. One rename applied: Task 7's `Tools.writeSource(script, compute)` is the single source writer used by `applySource` (Task 7) and `Agent.revertPlan` (Task 9).

