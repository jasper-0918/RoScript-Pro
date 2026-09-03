--[[ ═══════════════════════════════════════════════════════════════════════════
  RoScript Pro — Studio plugin v2 (Goal Mode)

  AI chat assistant inside Roblox Studio: free-tier Groq/OpenRouter/Cerebras
  rotation, auto game context (Explorer selection + open script), one-click
  Insert-as-Script and preview-gated Run-in-Studio, both undo-gated.

  Spec: docs/superpowers/specs/2026-09-02-roscript-studio-plugin-design.md
  Spec v2: docs/superpowers/specs/2026-09-03-roscript-goal-mode-design.md

  INSTALL (from the repo root, PowerShell):
    Copy-Item "studio-plugin\RoScriptPro.lua" "$env:LOCALAPPDATA\Roblox\Plugins\"
  then restart Studio once. If that folder doesn't exist, paste this file into a
  Script in Studio and use Plugins menu > Save as Local Plugin instead.

  RELOAD after editing (enable "Plugin Debugging Enabled" in Studio settings
  once): right-click the plugin under PluginDebugService > Save and Reload
  Plugin, or Ctrl+Shift+L to reload all. There is no hot-reload.

  Keys are stored via plugin settings, in plain text, on this machine only.
  Personal use. Never commit keys anywhere.
═══════════════════════════════════════════════════════════════════════════ ]]

-- ═══════════════════════ 1. CONFIG ═══════════════════════

local DEV = false -- true = print("[RSP]", ...) tracing

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

local PROV = {
	groq = { name = "Groq", url = "https://api.groq.com/openai/v1/chat/completions", strictTools = false },
	cerebras = { name = "Cerebras", url = "https://api.cerebras.ai/v1/chat/completions", strictTools = true },
	openrouter = { name = "OpenRouter", url = "https://openrouter.ai/api/v1/chat/completions", strictTools = false },
}
local PROV_ORDER = { "groq", "cerebras", "openrouter" }

-- Fixed failover order. Dead slugs classify as model-error and fail over, so the
-- chain is data: delete lines as providers deprecate. zai-glm-4.7 and
-- nemotron-3-super are PROVISIONAL (reasoning-family, no effort control) — cut
-- them if spike 4 shows hidden-reasoning wall-clock burn.
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

-- Output budgets sized to the undocumented (only-shortenable) HttpService
-- timeout: fast tiers get more room. Spike 4 finalizes.
local MAXTOK = { groq = 4096, cerebras = 8192, openrouter = 2048 }

-- OpenRouter attribution headers (their API asks for these; harmless elsewhere).
local OR_REFERER = "https://github.com/jasper-0918/RoScript-Pro"
local OR_TITLE = "RoScript Pro"

-- History is quota-driven, not timeout-driven: free tiers meter tokens/min+day,
-- so a small history roughly doubles session length per key.
local HISTORY_MAX_MSGS = 12
local HISTORY_MAX_CHARS = 15000

-- Context caps. CTX_MAX deliberately exceeds SEL_MAX + SCRIPT_MAX + overhead;
-- if the assembled block still exceeds it, the script tail is trimmed first.
local SEL_MAX = 2000
local SCRIPT_MAX = 8000
local SCRIPT_HEAD = 6000
local SCRIPT_TAIL = 2000
local CTX_MAX = 11000

local LABEL_MAX = 16000 -- chars per TextLabel; longer runs are split

-- Run engine: "loadstring" or "module" (ModuleScript + require fallback).
-- Spike 2 ran 2026-09-03 on this machine: BOTH passed; loadstring ships per
-- the spec tie-break (no DataModel churn, no module cache).
local RUN_ENGINE = "loadstring"

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

local COOLDOWN_DEFAULT = 30 -- seconds, when no Retry-After is readable
local COOLDOWN_NETFAIL = 15

-- UI hooks, forward-declared so PROVIDER/APPLY code (defined before the UI
-- section) can surface status without forward references. Filled in section 7.
local UI = {
	setStatus = function() end, -- (text, isError)
	addBubble = function() end, -- (role, text, opts)
	setBusy = function() end, -- (busy)
}

local function trace(...)
	if DEV then
		print("[RSP]", ...)
	end
end

-- Conversation state, declared early so both the UI section (Clear button)
-- and the bootstrap section can touch it. History stores bare text only —
-- context blocks are never persisted into it.
local history = {} -- { {role, content}, ... }
local gen = 0 -- generation counter: bumped on send/stop/unload; async work
-- captures its value and re-checks after every yield before touching UI.
local lastPrompt = nil
local lastUserBubble = nil

-- ═══════════════════════ 2. SETTINGS ═══════════════════════

-- In-memory cache over plugin:GetSetting/SetSetting. Documented hazard: with
-- two Studio windows open, reads can silently return nil — the cache keeps this
-- session self-consistent; last-writer-wins across windows is accepted.
local S = {}
do
	local cache = {}
	local KNOWN = { "keys_groq", "keys_openrouter", "keys_cerebras", "ctx_enabled", "active_skills",
		"goal_mode", "goal_focus", "goal_verify_enabled", "goal_careful", "goal_effort" }

	function S.get(key, default)
		if cache[key] ~= nil then
			return cache[key]
		end
		local ok, v = pcall(function()
			return plugin:GetSetting(key)
		end)
		if ok and v ~= nil then
			cache[key] = v
			return v
		end
		return default
	end

	function S.set(key, value)
		cache[key] = value
		local ok, err = pcall(function()
			plugin:SetSetting(key, value)
		end)
		if not ok then
			trace("SetSetting failed", key, err)
		end
	end

	function S.warm()
		for _, k in ipairs(KNOWN) do
			S.get(k, nil)
		end
	end
end

-- Key storage. SetSetting round-trips arrays as string-keyed maps ("1".."n"),
-- so load() normalizes both shapes back to a proper array — a naive ipairs
-- read would silently lose every key after a Studio restart.
local KeyStore = {}
do
	local function settingName(provider)
		return "keys_" .. provider
	end

	function KeyStore.load(provider)
		local raw = S.get(settingName(provider), nil)
		local keys = {}
		if type(raw) == "table" then
			local n = 0
			for _ in pairs(raw) do
				n += 1
			end
			for i = 1, n do
				local v = raw[i] or raw[tostring(i)]
				if type(v) == "string" and #v > 0 then
					table.insert(keys, v)
				end
			end
		end
		return keys
	end

	function KeyStore.save(provider, keys)
		S.set(settingName(provider), keys)
	end

	-- Returns true on success, or false + reason. Rejects characters the docs
	-- warn can corrupt the settings file (list not enumerated by Roblox; these
	-- two are the known offenders for JSON-on-disk).
	function KeyStore.add(provider, raw)
		local key = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if #key == 0 then
			return false, "empty key"
		end
		if key:find("\\", 1, true) or key:find('"', 1, true) then
			return false, "keys with \\ or \" can corrupt plugin settings"
		end
		local keys = KeyStore.load(provider)
		for _, existing in ipairs(keys) do
			if existing == key then
				return false, "key already added"
			end
		end
		table.insert(keys, key)
		KeyStore.save(provider, keys)
		return true
	end

	function KeyStore.remove(provider, index)
		local keys = KeyStore.load(provider)
		table.remove(keys, index)
		KeyStore.save(provider, keys)
	end

	function KeyStore.count()
		local n = 0
		for _, p in ipairs(PROV_ORDER) do
			n += #KeyStore.load(p)
		end
		return n
	end
end

-- ═══════════════════════ 3. PROMPT & SKILLS ═══════════════════════

local SYS_BASE = [==[You are RoScript Pro, an expert Roblox and Luau game development assistant running INSIDE Roblox Studio as a plugin.

ROBLOX/LUA STRICT RULES (never break):
1. task.wait() not wait() | task.spawn() not spawn() | task.delay() not delay()
2. ALL DataStore in pcall() with retry (exponential backoff, min 2 attempts)
3. Debounce on EVERY Touched event and EVERY Tool activation
4. Server validates ALL RemoteEvent data - never trust the client
5. Label placement: [Script - ServerScriptService] [LocalScript - StarterPlayerScripts]
6. Disconnect all connections on player/character removal; store in array
7. Luau types sparingly: local health: number = 100 only where it clarifies

DEEP THINK (every response): before writing code, silently restate what the code must do and its edge cases, trace the logic line by line catching nil cases, off-by-ones, client/server boundary mistakes and deprecated APIs, then write the final code. Code first, brief explanation after.

STUDIO CONTEXT: blocks between "=== STUDIO CONTEXT BEGIN ===" and "=== STUDIO CONTEXT END ===" describe the user's live place and open script. Treat them as ground truth about the game.

RUN CONTRACT: code meant for the Run button must be straight-line edit-time code: no yielding, no event connections, no task.spawn or coroutines, no long loops. Anything long-lived or event-driven must be a complete script for Insert instead.

INSERT CONTRACT: every complete script starts with this exact comment on line 1, inside a ```lua fence:
-- SCRIPT: <Name> | <Script|LocalScript|ModuleScript> | <ParentPath>
ParentPath is dot-separated instance Names from the top of the game, no "game." prefix - e.g. ServerScriptService or ServerScriptService.Systems

RESPONSE LENGTH: write complete code, never truncate, never use placeholder comments like "-- rest of code here". If cut off mid-response you will be asked to continue.

EFFICIENCY: no filler, no "Sure, here's..." openers, no restating the question, no closing summary. Code or answer first, brief explanation only where it genuinely helps.]==]

-- Skill packs, ported near-verbatim from the HTML app's DEFAULT_SKILLS.
-- Order here is canonical: buildSystemPrompt iterates THIS list (filtered by
-- the active set), never the active set itself, so the assembled prompt is
-- byte-identical for the same selection — providers prefix-cache it.
local SKILLS = {
	{
		id = "rblx-datastore",
		name = "DataStore Mastery",
		desc = "Retry patterns, session locks, auto-save",
		content = [==[DATASTORE EXPERT PATTERNS:
- Always pcall with exponential backoff retry (3 attempts, wait 2^n seconds between):
  local function safeGet(store, key)
    for attempt = 1, 3 do
      local ok, result = pcall(function() return store:GetAsync(key) end)
      if ok then return result end
      task.wait(2 ^ attempt)
    end
  end
- Use UpdateAsync (not SetAsync) for concurrent safety
- Auto-save every 60s via RunService.Heartbeat accumulator
- Always save on PlayerRemoving AND game:BindToClose (server shutdown)
- Key format: "plr_" .. player.UserId (never use username)
- Validate schema on load: if not data.coins then data.coins = 0 end
- OrderedDataStore for leaderboards; MessagingService for cross-server]==],
	},
	{
		id = "rblx-anticheat",
		name = "Anti-Exploit Shield",
		desc = "Server validation, rate limiting, sanity checks",
		content = [==[ANTI-EXPLOIT PATTERNS:
- NEVER trust the client for any game-affecting value
- All damage, purchases, stat changes must be server-authoritative
- RemoteEvent rate limiting (max ~10 calls/sec per player): keep a per-player
  table of call timestamps, drop old entries each call, ignore when over limit
- Sanity check ALL inputs: type(), math.clamp(), string length caps
- Server-side position validation: compare against Character.HumanoidRootPart
- Never use InvokeClient from the server (exploitable/yieldable)
- Use GetPropertyChangedSignal server-side to detect stat manipulation]==],
	},
	{
		id = "rblx-remotes",
		name = "Remote Architecture",
		desc = "Client-server patterns, event structure",
		content = [==[REMOTE EVENT ARCHITECTURE:
- Structure: ReplicatedStorage > Remotes folder > categorized subfolders
- Name convention: VerbNoun (PurchaseItem, DealDamage, UpdateUI)
- RemoteEvents for fire-and-forget; RemoteFunctions only for client->server queries
- Server always validates before acting; never trust client data
- Batch small frequent updates (update coins UI every 0.5s, not per coin)
- BindableEvents for same-environment communication
- ModuleScript for shared constants (damage values, item data)
- ReplicatedStorage for shared data; ServerStorage for server-only assets]==],
	},
	{
		id = "rblx-combat",
		name = "Combat Systems",
		desc = "Hitboxes, damage, debounce patterns",
		content = [==[COMBAT SYSTEM PATTERNS:
- Hitbox: workspace:GetPartBoundsInBox(cframe, size, params) - server-side always
- Debounce pattern on every Tool.Activated (flag + task.wait cooldown + unflag)
- Damage numbers: BillboardGui with TweenService float up + fade out
- Use Humanoid:TakeDamage() or set Health directly - validate server-side
- Hitbox params: RaycastParams/OverlapParams with FilterType.Exclude for attacker
- Swing animation: AnimationTrack:Play() with fade time
- Hit effects: ParticleEmitter:Emit(count) or clone VFX from ReplicatedStorage
- Never use Touched for combat hitboxes (unreliable); timed GetPartBoundsInBox]==],
	},
	{
		id = "rblx-ui",
		name = "UI & Tweening",
		desc = "GUI patterns, TweenService, responsive design",
		content = [==[ROBLOX UI BEST PRACTICES:
- TweenService for all animations - never set properties directly in loops
- UIAspectRatioConstraint for consistent cross-device scaling
- ScreenGui.IgnoreGuiInset = true for consistent positioning
- LocalScript in StarterPlayerScripts for persistent UI; StarterGui resets on respawn
- ResetOnSpawn = false for persistent GUIs
- BillboardGui for world-space labels (damage numbers, nametags, health bars)
- ZIndex layers: background=1, content=2, popups=3, notifications=4]==],
	},
	{
		id = "general-clean",
		name = "Clean Code",
		desc = "Naming conventions, structure, readability",
		content = [==[CLEAN CODE PRINCIPLES FOR GAME DEV:
- Single responsibility: each function/module does ONE thing
- Naming: descriptive verbs for functions (GetPlayerHealth, not GH)
- Constants at top of file in ALL_CAPS; no magic numbers
- Max function length ~30 lines; extract helpers beyond that
- Comments explain WHY, not WHAT
- Early returns / guard clauses over deep nesting
- DRY: copy-pasted twice means make it a function
- Game logic in ModuleScripts; UI in LocalScripts; networking in dedicated scripts
- Error handling at boundaries (DataStore, HTTP, pcall); assert internal invariants]==],
	},
	{
		id = "general-debug",
		name = "Debug Strategies",
		desc = "Systematic debugging, print patterns, profiling",
		content = [==[SYSTEMATIC DEBUGGING:
- Binary search: disable half the code, see if the bug persists, narrow down
- Print with context: print("[PlayerSystem] coins:", coins, "player:", player.Name)
- Check nil first: if not value then warn("nil at", script:GetFullName()) return end
- Studio debugger: breakpoints, Step Over F10, Step Into F11, Resume F5
- RemoteEvent bugs: print on BOTH client and server to see which side fails
- Performance: Microprofiler (Ctrl+F6) for frame-time bottlenecks
- Memory: Developer Console Memory tab; watch for growth over time
- assert() to catch programmer errors early: assert(type(damage) == "number")]==],
	},
}

local function activeSkillSet()
	local raw = S.get("active_skills", {})
	local set = {}
	if type(raw) == "table" then
		for _, id in pairs(raw) do
			if type(id) == "string" then
				set[id] = true
			end
		end
	end
	return set
end

local function saveActiveSkills(set)
	local arr = {}
	for _, skill in ipairs(SKILLS) do -- canonical order in storage too
		if set[skill.id] then
			table.insert(arr, skill.id)
		end
	end
	S.set("active_skills", arr)
end

-- Byte-identical for the same active-skill set. Never add timestamps or
-- per-call values here: providers cache the longest matching prompt PREFIX,
-- and this string is always first.
local function buildSystemPrompt()
	local active = activeSkillSet()
	local parts = { SYS_BASE }
	for _, skill in ipairs(SKILLS) do
		if active[skill.id] then
			table.insert(parts, "\n\n[SKILL PACK: " .. skill.name .. "]\n" .. skill.content)
		end
	end
	return table.concat(parts)
end

-- ═══════════════════════ 4. CONTEXT ═══════════════════════

-- Truncate to at most limit bytes WITHOUT cutting a UTF-8 character in half:
-- an invalid slice can corrupt or reject the JSON-encoded send.
local function utf8Trim(s, limit)
	if #s <= limit then
		return s
	end
	local boundary = utf8.offset(s, 0, limit + 1) -- start of the char occupying limit+1
	local cut = (boundary and boundary - 1) or limit
	return s:sub(1, math.max(cut, 0))
end

local function summarizeInstance(inst)
	local ok, line = pcall(function()
		local extra = ""
		if inst:IsA("BasePart") then
			local sz, pos = inst.Size, inst.Position
			extra = string.format(" | Size %g,%g,%g | Pos %g,%g,%g",
				math.floor(sz.X + 0.5), math.floor(sz.Y + 0.5), math.floor(sz.Z + 0.5),
				math.floor(pos.X + 0.5), math.floor(pos.Y + 0.5), math.floor(pos.Z + 0.5))
		elseif inst:IsA("Model") or inst:IsA("Folder") then
			local children = inst:GetChildren()
			local names = {}
			for i = 1, math.min(#children, 8) do
				table.insert(names, children[i].Name .. " (" .. children[i].ClassName .. ")")
			end
			extra = string.format(" | %d children: %s", #children, table.concat(names, ", "))
		elseif inst:IsA("LuaSourceContainer") then
			local okSrc, src = pcall(function()
				return ScriptEditorService:GetEditorSource(inst)
			end)
			if okSrc and type(src) == "string" then
				local _, lines = src:gsub("\n", "")
				extra = string.format(" | %d lines", lines + 1)
			end
		end
		return "- " .. inst:GetFullName() .. " | " .. inst.ClassName .. extra
	end)
	return ok and line or nil
end

local function buildSelectionSummary()
	local selected = Selection:Get()
	if #selected == 0 then
		return nil, 0
	end
	local shown = math.min(#selected, 20)
	local out = { string.format("Selection (%d of %d):", shown, #selected) }
	for i = 1, shown do
		local line = summarizeInstance(selected[i])
		if line then
			table.insert(out, line)
		end
	end
	return utf8Trim(table.concat(out, "\n"), SEL_MAX), #selected
end

local function getActiveScriptBlock()
	local active = StudioService.ActiveScript
	if not active then
		return nil, nil
	end
	local ok, src = pcall(function()
		return ScriptEditorService:GetEditorSource(active)
	end)
	if not ok or type(src) ~= "string" then
		return nil, nil
	end
	local _, lines = src:gsub("\n", "")
	local header = string.format("Active script: %s (%s, %d lines)", active:GetFullName(), active.ClassName, lines + 1)
	if #src > SCRIPT_MAX then
		local head = utf8Trim(src, SCRIPT_HEAD)
		-- Snap the tail cut to the START of the char containing the cut byte,
		-- and slice FROM it: the tail runs a few bytes long at most and is
		-- always valid UTF-8 (slicing from boundary+1 would begin mid-char).
		local i = #src - SCRIPT_TAIL + 1
		local b = utf8.offset(src, 0, math.min(i, #src)) or i
		local tail = src:sub(b)
		src = head .. "\n-- [... middle truncated by RoScript Pro ...]\n" .. tail
	end
	return header, src
end

-- Returns the context block (or nil) plus a short caption for the user bubble.
local function buildContext()
	if S.get("ctx_enabled", true) ~= true then
		return nil, nil
	end
	local selSummary, selCount = buildSelectionSummary()
	local scriptHeader, scriptSrc = getActiveScriptBlock()
	if not selSummary and not scriptHeader then
		return nil, nil
	end

	local parts = { "=== STUDIO CONTEXT BEGIN ===" }
	if selSummary then
		table.insert(parts, selSummary)
	end
	if scriptHeader then
		table.insert(parts, scriptHeader)
		table.insert(parts, scriptSrc)
	end
	table.insert(parts, "=== STUDIO CONTEXT END ===")
	local block = table.concat(parts, "\n")

	-- Enforce the whole-block cap by trimming the script tail first.
	if #block > CTX_MAX and scriptSrc then
		local overflow = #block - CTX_MAX
		scriptSrc = utf8Trim(scriptSrc, math.max(#scriptSrc - overflow - 40, 0))
			.. "\n-- [... trimmed to context cap ...]"
		parts = { "=== STUDIO CONTEXT BEGIN ===" }
		if selSummary then
			table.insert(parts, selSummary)
		end
		table.insert(parts, scriptHeader)
		table.insert(parts, scriptSrc)
		table.insert(parts, "=== STUDIO CONTEXT END ===")
		block = table.concat(parts, "\n")
	end
	block = utf8Trim(block, CTX_MAX + 200) -- absolute backstop

	local capParts = {}
	if selCount and selCount > 0 then
		table.insert(capParts, selCount .. " selected")
	end
	if scriptHeader then
		local name = StudioService.ActiveScript and StudioService.ActiveScript.Name or "script"
		table.insert(capParts, name)
	end
	return block, "with context: " .. table.concat(capParts, " · ")
end

-- ═══════════════════════ 5. PROVIDER ═══════════════════════

local Cooling = {} -- "provider:idx" -> os.clock() deadline
local Bad = {} -- "provider:idx" -> true (invalid key, session-scoped)
local EffortStripped = {} -- provider -> true once a 400 named reasoning_effort

local function keyId(entry)
	return entry.p .. ":" .. entry.idx
end

local function isAvailable(entry)
	local id = keyId(entry)
	if Bad[id] then
		return false
	end
	local deadline = Cooling[id]
	if deadline then
		if os.clock() >= deadline then
			Cooling[id] = nil
		else
			return false
		end
	end
	return true
end

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

-- Luau patterns have no "|" alternation: every classifier is a list of
-- patterns tried in order against the lowercased subject.
local function matchAny(s, patterns)
	s = (s or ""):lower()
	for _, pat in ipairs(patterns) do
		if s:find(pat) then
			return true
		end
	end
	return false
end

local PAT_RATELIMIT = { "rate.?limit", "quota", "too many" }
local PAT_AUTH = { "invalid.api.key", "unauthorized", "invalid_api_key", "authentication" }
local PAT_MODELDEAD = { "model_not_found", "no endpoints", "does not exist", "not found", "unavailable", "invalid model" }
local PAT_TOOLARGE = { "request too large", "body is too large", "context_length", "maximum context", "too many tokens", "reduce the length" }
local PAT_PERMISSION = { "not allowed", "permission", "denied" }
local PAT_REFUSAL = { "i can'?t", "i cannot", "i'm sorry", "i am unable", "cannot assist" }

local function looksLikeRefusal(text)
	return #text < 400 and not text:find("```", 1, true) and matchAny(text, PAT_REFUSAL)
end

local function retryAfterSeconds(headers, bodyText)
	if type(headers) == "table" then
		for k, v in pairs(headers) do
			if type(k) == "string" and k:lower() == "retry-after" then
				local n = tonumber(v)
				if n and n > 0 then
					return math.min(n, 3600)
				end
			end
		end
	end
	local n = tonumber((bodyText or ""):match("[Rr]etry.-(%d+)"))
	if n and n > 0 then
		return math.min(n, 3600)
	end
	return nil
end

-- Classifies a failed attempt, mutating cooldown/bad/per-send state.
-- Returns reason (short text) and action: "next" | "retry-stripped" | "retry-same".
local function classifyFailure(entry, code, bodyText, headers, pcallErr, state)
	local id = keyId(entry)
	local pname = PROV[entry.p].name

	if pcallErr then
		Cooling[id] = os.clock() + COOLDOWN_NETFAIL
		if matchAny(pcallErr, PAT_PERMISSION) then
			return pname .. ": Studio blocked the request — check Plugin Management permissions", "next"
		end
		return pname .. ": " .. utf8Trim(tostring(pcallErr), 80), "next"
	end

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
end

-- One request. Returns table {text, toolCalls, reasoning, usage, truncated, entry}
-- on success, or nil, code, bodyText, headers, pcallErr on failure.
local function callProvider(entry, messages, opts)
	opts = opts or {}
	local headers = {
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. entry.key,
	}
	if entry.p == "openrouter" then
		headers["HTTP-Referer"] = OR_REFERER
		headers["X-Title"] = OR_TITLE
	end
	local body = {
		model = entry.m,
		messages = messages,
		max_tokens = opts.maxTokens or MAXTOK[entry.p],
		temperature = opts.temperature or 0.5,
	}
	if opts.goal then body.max_tokens = GOAL_MAXTOK[entry.p] end
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
	local okEnc, encoded = pcall(function()
		return HttpService:JSONEncode(body)
	end)
	if not okEnc then
		return nil, nil, "", nil, "JSON encode failed: " .. tostring(encoded)
	end

	trace("->", entry.p, entry.m, "#" .. entry.idx, #encoded .. "B")
	local okReq, resp = pcall(function()
		return HttpService:RequestAsync({
			Url = PROV[entry.p].url,
			Method = "POST",
			Headers = headers,
			Body = encoded,
		})
	end)
	if not okReq then
		return nil, nil, "", nil, tostring(resp)
	end

	local bodyText = resp.Body or ""
	if not resp.Success then
		return nil, resp.StatusCode, bodyText, resp.Headers, nil
	end

	local okDec, decoded = pcall(function()
		return HttpService:JSONDecode(bodyText)
	end)
	if not okDec or type(decoded) ~= "table" then
		return nil, resp.StatusCode, "malformed json body", resp.Headers, nil
	end

	-- A 200 whose body is {"error":...} with no choices (OpenRouter does this
	-- for moderation blocks and dead upstreams) classifies through the normal
	-- table — treating it as "malformed" would never cool the key.
	local choice = decoded.choices and decoded.choices[1]
	if not choice or not choice.message then
		local err = decoded.error or {}
		-- Fold a string error.code (e.g. "invalid_api_key") into the classified
		-- text so the pattern tables can see it even when the message is bland.
		local msg = tostring(err.code or "") .. " " .. tostring(err.message or "no choices in response")
		local codeGuess = tonumber(err.code) or resp.StatusCode
		return nil, codeGuess, msg, resp.Headers, nil
	end

	local msg = choice.message
	local text = msg.content
	local calls = msg.tool_calls
	if (type(text) ~= "string" or text:gsub("%s", "") == "") and not (type(calls) == "table" and #calls > 0) then
		return nil, resp.StatusCode, "empty content", resp.Headers, nil
	end
	return {
		text = (type(text) == "string" and text ~= "") and text or nil,
		toolCalls = (type(calls) == "table" and #calls > 0) and calls or nil,
		reasoning = (type(msg.reasoning) == "string" and msg.reasoning ~= "") and msg.reasoning or nil,
		usage = decoded.usage,
		truncated = (choice.finish_reason == "length"),
		entry = entry,
	}
end

-- Walks the queue once; first success wins. state carries per-send
-- failedModels/failedProviders sets. statusFn is a caller-provided closure
-- that internally checks the generation counter, so an orphaned (stopped)
-- walk can never write stale status to the UI.
local function chatOnce(messages, state, statusFn, opts)
	statusFn = statusFn or function() end
	opts = opts or {}
	local queue = buildQueue(opts.goal == true)
	if #queue == 0 then
		if KeyStore.count() == 0 then
			return nil, "Add a free Groq/OpenRouter/Cerebras key in Settings (gear button)."
		end
		return nil, "All keys are cooling down or invalid. Wait a moment and Retry."
	end
	local lastReason = nil
	local sizeSkipped = 0
	local i = 1
	while i <= #queue do
		local entry = queue[i]
		local otherSkip = state.failedModels[entry.p .. ":" .. entry.m]
			or state.failedProviders[entry.p]
			or not isAvailable(entry)
		local sizeSkip = opts.estTokens and entry.p == "groq" and opts.estTokens > GROQ_REQ_MAX
		local skip = otherSkip or sizeSkip
		if sizeSkip and not otherSkip then
			sizeSkipped += 1
		end
		if not skip then
			statusFn("Thinking — " .. PROV[entry.p].name .. " " .. entry.m)
			local result, code, bodyText, respHeaders, pcallErr = callProvider(entry, messages, opts)
			if result then
				return result
			end
			local reason, action = classifyFailure(entry, code, bodyText, respHeaders, pcallErr, state)
			trace("fail", reason, action)
			lastReason = reason
			if action == "retry-stripped" then
				-- Same entry, one immediate retry with reasoning_effort stripped
				-- (EffortStripped[p] is already set, so callProvider omits it).
				local retryResult, c2, b2, h2, e2 = callProvider(entry, messages, opts)
				if retryResult then
					return retryResult
				end
				-- Classify the retry's own failure too, or a 429 here would
				-- never cool the key and it gets hammered by later entries.
				lastReason = classifyFailure(entry, c2, b2, h2, e2, state)
			elseif action == "retry-same" and not state.retriedSame then
				state.retriedSame = true
				local retryOpts = table.clone(opts); retryOpts.temperature = 0
				local r2, c2, b2, h2, e2 = callProvider(entry, messages, retryOpts)
				if r2 then return r2 end
				lastReason = classifyFailure(entry, c2, b2, h2, e2, state)
			end
		end
		i += 1
	end
	if sizeSkipped > 0 and sizeSkipped == #queue then
		return nil, ("Request is ~%d tokens; Groq's 8K limit excludes it and no Cerebras or OpenRouter key is available. Add one in Settings or narrow the goal."):format(opts.estTokens)
	end
	return nil, (lastReason or "every key failed") .. " — chain exhausted. Retry when keys cool down."
end

-- One automatic continuation round on truncation: same entry first (it just
-- proved alive), then the fresh queue. Never more than one round.
local function chatWithContinuation(messages, statusFn)
	local state = { failedModels = {}, failedProviders = {} }
	local result, err = chatOnce(messages, state, statusFn)
	if not result then
		return nil, err
	end
	if not result.truncated then
		return result
	end

	local contMessages = table.clone(messages)
	table.insert(contMessages, { role = "assistant", content = result.text })
	table.insert(contMessages, {
		role = "user",
		content = "Continue exactly where you stopped. Do not repeat anything. No preamble.",
	})
	local cont = callProvider(result.entry, contMessages)
	if not cont then
		cont = chatOnce(contMessages, state, statusFn)
	end
	if cont then
		return {
			text = result.text .. cont.text,
			truncated = cont.truncated,
			entry = cont.entry,
		}
	end
	return result -- ship the truncated text honestly; UI adds the footer
end

-- ═══════════════════════ 6. APPLY & RUN ═══════════════════════

local CONTAINER_WHITELIST = {
	Folder = true,
	Model = true,
	Workspace = true,
	ServerScriptService = true,
	ServerStorage = true,
	ReplicatedStorage = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayerScripts = true,
	StarterCharacterScripts = true,
	Tool = true,
}

local VALID_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local function defaultParentFor(class)
	if class == "LocalScript" then
		local sp = game:GetService("StarterPlayer")
		return sp:FindFirstChild("StarterPlayerScripts") or sp
	elseif class == "ModuleScript" then
		return game:GetService("ReplicatedStorage")
	end
	return game:GetService("ServerScriptService")
end

local function walkPath(path)
	path = path:gsub("^game%.", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if path:lower() == "workspace" then
		return game:GetService("Workspace")
	end
	local node = game
	for segment in path:gmatch("[^%.]+") do
		if segment:lower() == "workspace" and node == game then
			node = game:GetService("Workspace")
		else
			node = node:FindFirstChild(segment)
			if not node then
				return nil
			end
		end
	end
	return node ~= game and node or nil
end

-- Parses the line-1 contract "-- SCRIPT: Name | Class | ParentPath".
-- Falls back to heuristics. Returns name, class, parentPath (path may be nil).
local function parsePlacement(code)
	local name, class, parentPath = code:match("^%-%-%s*SCRIPT:%s*([^|]+)|%s*([^|]+)|%s*([^\r\n]+)")
	if name and class then
		name = name:gsub("%s+$", ""):gsub("^%s+", "")
		class = class:gsub("%s+$", ""):gsub("^%s+", "")
		parentPath = parentPath and parentPath:gsub("%s+$", ""):gsub("^%s+", "") or nil
		if VALID_CLASSES[class] and #name > 0 then
			return name, class, parentPath
		end
	end
	-- Heuristics when the model omitted the contract.
	if matchAny(code, { "localplayer", "userinputservice", "contextactionservice" }) then
		return "GeneratedLocalScript", "LocalScript", nil
	end
	if code:match("^%s*local%s+%w+%s*=%s*{}") and code:match("return%s+%w+%s*$") then
		return "GeneratedModule", "ModuleScript", nil
	end
	return "GeneratedScript", "Script", nil
end

-- Full resolution with explicit precedence: selection override (exactly one
-- whitelisted container selected) > contract path > class fallback.
local function resolvePlacement(code)
	local name, class, parentPath = parsePlacement(code)
	local parent, via

	local selected = Selection:Get()
	if #selected == 1 and CONTAINER_WHITELIST[selected[1].ClassName] then
		parent, via = selected[1], "selection"
	end
	if not parent and parentPath then
		parent = walkPath(parentPath)
		via = parent and "contract" or nil
	end
	if not parent then
		parent, via = defaultParentFor(class), "fallback"
	end
	return { name = name, class = class, parent = parent, via = via }
end

local function placementLabel(placement)
	local okName, full = pcall(function()
		return placement.parent:GetFullName()
	end)
	return "→ " .. (okName and full or "?") .. " (" .. placement.class .. ")"
end

local function insertScript(code)
	local placement = resolvePlacement(code)
	local recId = ChangeHistoryService:TryBeginRecording("RoScriptPro Insert", "RoScript Pro: Insert " .. placement.name)
	if not recId then
		UI.setStatus("Undo unavailable (playtest running?) — not inserting", true)
		return false
	end
	local okBuild, errOrInst = pcall(function()
		local s = Instance.new(placement.class)
		s.Name = placement.name
		s.Source = code -- Script Injection permission can make this throw
		s.Parent = placement.parent
		return s
	end)
	if not okBuild then
		ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Cancel)
		if matchAny(tostring(errOrInst), PAT_PERMISSION) then
			UI.setStatus("Enable Script Injection for RoScript Pro in Plugin Management, then retry", true)
		else
			UI.setStatus("Insert failed: " .. utf8Trim(tostring(errOrInst), 100), true)
		end
		return false
	end
	ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Commit)
	pcall(function()
		ScriptEditorService:OpenScriptDocumentAsync(errOrInst)
	end)
	UI.setStatus("Inserted " .. errOrInst:GetFullName() .. " (undo: Ctrl+Z)", false)
	return true
end

-- Runs a snippet once at edit time, undo-gated. Returns ok, stage, message.
-- stage is "compile" or "runtime" on failure.
local function runOnce(code)
	local recId = ChangeHistoryService:TryBeginRecording("RoScriptPro Run", "RoScript Pro: Run snippet")
	if not recId then
		UI.setStatus("Undo unavailable — refusing to run", true)
		return false, "compile", "undo unavailable"
	end

	local fn, compileErr
	if RUN_ENGINE == "loadstring" then
		-- loadstring returns nil, errmsg on syntax errors: capture BOTH.
		local f, e
		local okLS = pcall(function()
			f, e = loadstring(code)
		end)
		if okLS and type(f) == "function" then
			fn = f
		else
			compileErr = tostring(e or f or "loadstring unavailable in this context")
		end
	else
		local okBuild, modOrErr = pcall(function()
			local m = Instance.new("ModuleScript")
			m.Name = "_RoScriptProRunner"
			m.Source = "return function()\n" .. code .. "\nend" -- injection gate can throw
			m.Parent = ServerStorage
			return m
		end)
		if not okBuild then
			ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Cancel)
			if matchAny(tostring(modOrErr), PAT_PERMISSION) then
				UI.setStatus("Enable Script Injection for RoScript Pro in Plugin Management, then retry", true)
			else
				UI.setStatus("Run setup failed: " .. utf8Trim(tostring(modOrErr), 100), true)
			end
			return false, "compile", tostring(modOrErr)
		end
		local okC, fnOrErr = pcall(require, modOrErr)
		modOrErr:Destroy()
		if okC and type(fnOrErr) == "function" then
			fn = fnOrErr
		else
			compileErr = tostring(fnOrErr)
		end
	end

	if not fn then
		-- User code never ran: nothing to keep.
		ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Cancel)
		return false, "compile", compileErr or "could not compile"
	end

	local okR, runErr = pcall(fn)
	-- User code ran at all → Commit, even on a runtime error: partial changes
	-- stay visible and undoable (spike 7 may refine Cancel semantics).
	ChangeHistoryService:FinishRecording(recId, Enum.FinishRecordingOperation.Commit)
	if okR then
		UI.setStatus("Ran OK (undo: Ctrl+Z)", false)
		return true
	end
	warn("[RoScript Pro] runtime error:", runErr)
	return false, "runtime", tostring(runErr)
end

-- ═══════════════════════ 7. UI ═══════════════════════

local C = {
	BG = Color3.fromHex("111826"),
	PANEL = Color3.fromHex("1a2332"),
	PANEL2 = Color3.fromHex("232f44"),
	CODEBG = Color3.fromHex("0b101c"),
	ACCENT = Color3.fromHex("8B4BCF"),
	TEXT = Color3.fromHex("e5e7eb"),
	MUTED = Color3.fromHex("9aa3b5"),
	ERR = Color3.fromHex("ef4444"),
	OK = Color3.fromHex("4ade80"),
}

local function mk(class, props, parent)
	local inst = Instance.new(class)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0 -- UIComponents (UICorner etc.) don't have it
	end
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function escapeRich(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Split assistant text into prose and ```-fenced code blocks; tolerates an
-- unclosed final fence (truncated responses).
local function splitBlocks(text)
	local blocks = {}
	local function pushText(body)
		if body and body:gsub("%s", "") ~= "" then
			table.insert(blocks, { kind = "text", body = body })
		end
	end
	local pos = 1
	while true do
		local s = text:find("```", pos, true)
		if not s then
			break
		end
		pushText(text:sub(pos, s - 1))
		local nl = text:find("\n", s, true)
		if not nl then
			pushText(text:sub(s))
			return blocks
		end
		local e = text:find("```", nl + 1, true)
		if e then
			table.insert(blocks, { kind = "code", body = (text:sub(nl + 1, e - 1):gsub("\n$", "")) })
			pos = e + 3
		else
			table.insert(blocks, { kind = "code", body = text:sub(nl + 1) })
			return blocks
		end
	end
	pushText(text:sub(pos))
	return blocks
end

-- Split long runs at newline boundaries so no label exceeds LABEL_MAX.
local function chunkText(s)
	if #s <= LABEL_MAX then
		return { s }
	end
	local chunks = {}
	local pos = 1
	while pos <= #s do
		local last = math.min(pos + LABEL_MAX - 1, #s)
		if last < #s then
			local nl = s:sub(pos, last):find("\n[^\n]*$")
			if nl and nl > 1 then
				last = pos + nl - 1
			end
		end
		table.insert(chunks, s:sub(pos, last))
		pos = last + 1
	end
	return chunks
end

-- Everything below is wired inside buildUI(widget); these locals are the
-- shared UI state the bootstrap section also touches.
local widget = nil
local unloaded = false
local bubbleOrder = 0
local chatScroll, statusLabel, inputBox, sendButton, ctxButton
local settingsPanel, modalHost
local onSendRef = function() end
local onStopRef = function() end
local busyState = false

local function widgetAlive()
	return widget ~= nil and not unloaded
end

local function scrollToBottom()
	if not chatScroll then
		return
	end
	task.defer(function()
		if widgetAlive() then
			chatScroll.CanvasPosition = Vector2.new(0, math.max(chatScroll.AbsoluteCanvasSize.Y, 0))
		end
	end)
end

local function closeModal()
	if modalHost then
		modalHost:ClearAllChildren()
		modalHost.Visible = false
	end
end

local function openModalPanel(titleText)
	modalHost.Visible = true
	local panel = mk("Frame", {
		BackgroundColor3 = C.PANEL,
		Size = UDim2.new(1, -24, 1, -24),
		Position = UDim2.new(0, 12, 0, 12),
		Active = true, -- sink clicks so the UI underneath can't be hit
	}, modalHost)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30) }, panel)
	mk("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -40, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = C.TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = titleText,
	}, bar)
	local closeBtn = mk("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 30, 0, 30),
		Position = UDim2.new(1, -30, 0, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = C.MUTED,
		Text = "X",
	}, bar)
	closeBtn.Activated:Connect(closeModal)
	local body = mk("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -20, 1, -40),
		Position = UDim2.new(0, 10, 0, 32),
	}, panel)
	return body
end

-- Read-only selectable source view: the copy affordance (no clipboard API).
local function openSourceModal(code)
	local body = openModalPanel("Source — select and Ctrl+C to copy")
	local scroll = mk("ScrollingFrame", {
		BackgroundColor3 = C.CODEBG,
		Size = UDim2.new(1, 0, 1, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarThickness = 6,
	}, body)
	mk("TextBox", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(0, 0, 0, 0),
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = C.TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = code,
		TextEditable = false,
		ClearTextOnFocus = false,
		MultiLine = true,
	}, scroll)
end

local function openPreviewModal(code, blockStatus)
	local body = openModalPanel("Run once in Studio")
	mk("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextWrapped = true,
		TextColor3 = C.MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Runs immediately at edit time. One undo step. Yielding code may outlive the undo recording.",
	}, body)
	local scroll = mk("ScrollingFrame", {
		BackgroundColor3 = C.CODEBG,
		Size = UDim2.new(1, 0, 1, -76),
		Position = UDim2.new(0, 0, 0, 38),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarThickness = 6,
	}, body)
	mk("TextBox", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(0, 0, 0, 0),
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = C.TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = code,
		TextEditable = false,
		ClearTextOnFocus = false,
		MultiLine = true,
	}, scroll)
	local row = mk("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 1, -30),
	}, body)
	local runBtn = mk("TextButton", {
		BackgroundColor3 = C.ACCENT,
		Size = UDim2.new(0, 110, 0, 26),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.TEXT,
		Text = "Run once",
	}, row)
	mk("UICorner", { CornerRadius = UDim.new(0, 5) }, runBtn)
	local cancelBtn = mk("TextButton", {
		BackgroundColor3 = C.PANEL2,
		Size = UDim2.new(0, 80, 0, 26),
		Position = UDim2.new(0, 118, 0, 0),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = C.MUTED,
		Text = "Cancel",
	}, row)
	mk("UICorner", { CornerRadius = UDim.new(0, 5) }, cancelBtn)
	cancelBtn.Activated:Connect(closeModal)
	runBtn.Activated:Connect(function()
		if not runBtn.Active then
			return
		end
		runBtn.Active = false -- runs once; re-arm by reopening the preview
		runBtn.Text = "Running…"
		local ok, stage, msg = runOnce(code)
		closeModal()
		if ok then
			blockStatus.TextColor3 = C.OK
			blockStatus.Text = "Ran OK (undo: Ctrl+Z)"
		else
			blockStatus.TextColor3 = C.ERR
			blockStatus.Text = (stage == "compile" and "Syntax error: " or "Runtime error: ") .. utf8Trim(msg or "?", 200)
		end
		blockStatus.Visible = true
	end)
end

local function renderCodeBlock(parentFrame, code)
	local frame = mk("Frame", {
		BackgroundColor3 = C.CODEBG,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	}, parentFrame)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, frame)
	local layout = mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, frame)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}, frame)

	local header = mk("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 1,
	}, frame)
	local function headerBtn(text, xOff, w)
		local b = mk("TextButton", {
			BackgroundColor3 = C.PANEL2,
			Size = UDim2.new(0, w, 0, 20),
			Position = UDim2.new(0, xOff, 0, 0),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = C.TEXT,
			Text = text,
		}, header)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
		return b
	end
	local insertBtn = headerBtn("Insert Script", 0, 80)
	local runBtn = headerBtn("Run", 86, 40)
	local viewBtn = headerBtn("View", 132, 44)
	local tagLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -184, 0, 20),
		Position = UDim2.new(0, 182, 0, 0),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = C.MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = placementLabel(resolvePlacement(code)),
	}, header)

	local order = 2
	for _, chunk in ipairs(chunkText(code)) do
		mk("TextLabel", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			Font = Enum.Font.Code,
			TextSize = 13,
			TextWrapped = true,
			TextColor3 = C.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			RichText = false,
			Text = chunk,
			LayoutOrder = order,
		}, frame)
		order += 1
	end

	local blockStatus = mk("TextLabel", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = C.ERR,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Visible = false,
		LayoutOrder = order,
	}, frame)

	insertBtn.Activated:Connect(function()
		-- Selection may have changed since render: re-resolve fresh; if the
		-- destination moved, first click only updates the tag (click again).
		local fresh = placementLabel(resolvePlacement(code))
		if fresh ~= tagLabel.Text then
			tagLabel.Text = fresh
			UI.setStatus("Target updated — click Insert again to confirm", false)
			return
		end
		insertScript(code)
	end)
	runBtn.Activated:Connect(function()
		openPreviewModal(code, blockStatus)
	end)
	viewBtn.Activated:Connect(function()
		openSourceModal(code)
	end)
	return frame
end

local function addBubble(role, text, opts)
	opts = opts or {}
	bubbleOrder += 1
	local isUser = role == "user"
	local bubble = mk("Frame", {
		BackgroundColor3 = isUser and C.PANEL2 or C.PANEL,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -16, 0, 0),
		LayoutOrder = bubbleOrder,
	}, chatScroll)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, bubble)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
	}, bubble)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, bubble)
	if isUser then
		mk("UIStroke", { Color = C.ACCENT, Thickness = 1, Transparency = 0.5 }, bubble)
	end

	local order = 1
	local function addProse(body, color)
		for _, chunk in ipairs(chunkText(body)) do
			mk("TextLabel", {
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextWrapped = true,
				RichText = true,
				TextColor3 = color or C.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Text = escapeRich(chunk),
				LayoutOrder = order,
			}, bubble)
			order += 1
		end
	end

	if role == "assistant" then
		for _, block in ipairs(splitBlocks(text)) do
			if block.kind == "code" then
				local codeFrame = renderCodeBlock(bubble, block.body)
				codeFrame.LayoutOrder = order
				order += 1
			else
				addProse(block.body)
			end
		end
	elseif role == "error" then
		addProse(text, C.ERR)
		if opts.retry then
			local retryBtn = mk("TextButton", {
				BackgroundColor3 = C.PANEL2,
				Size = UDim2.new(0, 70, 0, 24),
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = C.TEXT,
				Text = "Retry",
				LayoutOrder = order,
			}, bubble)
			order += 1
			mk("UICorner", { CornerRadius = UDim.new(0, 5) }, retryBtn)
			retryBtn.Activated:Connect(function()
				onSendRef(nil, true)
			end)
		end
	else
		addProse(text)
	end

	if opts.caption then
		mk("TextLabel", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextWrapped = true,
			TextColor3 = C.MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = opts.caption,
			Name = "Caption",
			LayoutOrder = order,
		}, bubble)
		order += 1
	end
	if opts.footer then
		mk("TextLabel", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextWrapped = true,
			TextColor3 = C.MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = opts.footer,
			LayoutOrder = order,
		}, bubble)
	end
	scrollToBottom()
	return bubble
end

local function setStatus(text, isError)
	if not widgetAlive() then
		return
	end
	statusLabel.TextColor3 = isError and C.ERR or C.MUTED
	statusLabel.Text = text
end

local function setBusy(b)
	busyState = b
	if not widgetAlive() then
		return
	end
	inputBox.TextEditable = not b
	sendButton.Text = b and "Stop" or "Send"
	sendButton.BackgroundColor3 = b and C.ERR or C.ACCENT
	if not b then
		setStatus("Ready", false)
	end
end

local function clearConversation()
	for _, child in ipairs(chatScroll:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	bubbleOrder = 0
	table.clear(history)
	lastPrompt = nil
	lastUserBubble = nil
end

local function maskKey(key)
	if #key <= 8 then
		return "····"
	end
	return "····" .. key:sub(-4)
end

local renderSettings -- defined below, referenced by buildUI

local function buildUI(w)
	widget = w
	local root = mk("Frame", { BackgroundColor3 = C.BG, Size = UDim2.new(1, 0, 1, 0) }, widget)

	-- Top bar
	local topBar = mk("Frame", { BackgroundColor3 = C.PANEL, Size = UDim2.new(1, 0, 0, 30) }, root)
	statusLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -110, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = C.MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "Ready",
	}, topBar)
	ctxButton = mk("TextButton", {
		BackgroundColor3 = C.PANEL2,
		Size = UDim2.new(0, 56, 0, 22),
		Position = UDim2.new(1, -100, 0, 4),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = C.TEXT,
		Text = S.get("ctx_enabled", true) == true and "CTX:ON" or "CTX:OFF",
	}, topBar)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, ctxButton)
	local gearButton = mk("TextButton", {
		BackgroundColor3 = C.PANEL2,
		Size = UDim2.new(0, 36, 0, 22),
		Position = UDim2.new(1, -40, 0, 4),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = C.TEXT,
		Text = "Set",
	}, topBar)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, gearButton)

	-- Chat scroll
	chatScroll = mk("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -98),
		Position = UDim2.new(0, 0, 0, 32),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, root)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, chatScroll)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
	}, chatScroll)

	-- Input bar
	local inputBar = mk("Frame", {
		BackgroundColor3 = C.PANEL,
		Size = UDim2.new(1, 0, 0, 64),
		Position = UDim2.new(0, 0, 1, -64),
	}, root)
	inputBox = mk("TextBox", {
		BackgroundColor3 = C.PANEL2,
		Size = UDim2.new(1, -86, 0, 48),
		Position = UDim2.new(0, 8, 0, 8),
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = C.TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		ClearTextOnFocus = false,
		MultiLine = false,
		PlaceholderText = "Ask about your game… (Enter sends)",
		PlaceholderColor3 = C.MUTED,
		Text = "",
	}, inputBar)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, inputBox)
	mk("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, inputBox)
	sendButton = mk("TextButton", {
		BackgroundColor3 = C.ACCENT,
		Size = UDim2.new(0, 64, 0, 48),
		Position = UDim2.new(1, -72, 0, 8),
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.TEXT,
		Text = "Send",
	}, inputBar)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, sendButton)

	-- Overlays
	settingsPanel = mk("Frame", {
		BackgroundColor3 = C.BG,
		Size = UDim2.new(1, 0, 1, -98),
		Position = UDim2.new(0, 0, 0, 32),
		Visible = false,
	}, root)
	modalHost = mk("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		Size = UDim2.new(1, 0, 1, 0),
		Visible = false,
		ZIndex = 5,
		Active = true, -- sink clicks so the UI underneath can't be hit
	}, root)

	-- Wiring
	sendButton.Activated:Connect(function()
		if busyState then
			onStopRef()
		else
			onSendRef(inputBox.Text, false)
		end
	end)
	inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed and not busyState then
			onSendRef(inputBox.Text, false)
		end
	end)
	ctxButton.Activated:Connect(function()
		local now = not (S.get("ctx_enabled", true) == true)
		S.set("ctx_enabled", now)
		ctxButton.Text = now and "CTX:ON" or "CTX:OFF"
	end)
	gearButton.Activated:Connect(function()
		settingsPanel.Visible = not settingsPanel.Visible
		if settingsPanel.Visible then
			renderSettings()
		end
	end)

	UI.setStatus = setStatus
	UI.addBubble = addBubble
	UI.setBusy = setBusy
end

renderSettings = function()
	settingsPanel:ClearAllChildren()
	local scroll = mk("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, settingsPanel)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, scroll)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 8),
	}, scroll)

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end
	local function sectionLabel(text)
		mk("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 20),
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = C.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = text,
			LayoutOrder = nextOrder(),
		}, scroll)
	end

	for _, p in ipairs(PROV_ORDER) do
		sectionLabel(PROV[p].name .. " keys")
		local keys = KeyStore.load(p)
		for i, key in ipairs(keys) do
			local row = mk("Frame", {
				BackgroundColor3 = C.PANEL,
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = nextOrder(),
			}, scroll)
			mk("UICorner", { CornerRadius = UDim.new(0, 4) }, row)
			mk("TextLabel", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -40, 1, 0),
				Position = UDim2.new(0, 8, 0, 0),
				Font = Enum.Font.Code,
				TextSize = 11,
				TextColor3 = C.MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "#" .. i .. "  " .. maskKey(key),
			}, row)
			local del = mk("TextButton", {
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 26, 1, 0),
				Position = UDim2.new(1, -30, 0, 0),
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = C.ERR,
				Text = "x",
			}, row)
			del.Activated:Connect(function()
				KeyStore.remove(p, i)
				renderSettings()
			end)
		end
		local addRow = mk("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = nextOrder(),
		}, scroll)
		local box = mk("TextBox", {
			BackgroundColor3 = C.PANEL2,
			Size = UDim2.new(1, -60, 1, -4),
			Font = Enum.Font.Code,
			TextSize = 11,
			TextColor3 = C.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
			PlaceholderText = "paste " .. PROV[p].name .. " key…",
			PlaceholderColor3 = C.MUTED,
			Text = "",
		}, addRow)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, box)
		mk("UIPadding", { PaddingLeft = UDim.new(0, 6) }, box)
		local addBtn = mk("TextButton", {
			BackgroundColor3 = C.PANEL2,
			Size = UDim2.new(0, 50, 1, -4),
			Position = UDim2.new(1, -54, 0, 0),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = C.TEXT,
			Text = "Add",
		}, addRow)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, addBtn)
		addBtn.Activated:Connect(function()
			local ok, reason = KeyStore.add(p, box.Text)
			if ok then
				box.Text = ""
				renderSettings()
			else
				setStatus(reason, true)
			end
		end)
	end

	sectionLabel("Skill packs")
	local active = activeSkillSet()
	for _, skill in ipairs(SKILLS) do
		local on = active[skill.id] == true
		local row = mk("TextButton", {
			BackgroundColor3 = on and C.PANEL2 or C.PANEL,
			Size = UDim2.new(1, 0, 0, 30),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = on and C.TEXT or C.MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = (on and "  [x] " or "  [ ] ") .. skill.name .. " — " .. skill.desc,
			LayoutOrder = nextOrder(),
		}, scroll)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, row)
		row.Activated:Connect(function()
			local set = activeSkillSet()
			set[skill.id] = not set[skill.id] or nil
			saveActiveSkills(set)
			renderSettings()
		end)
	end

	local clearBtn = mk("TextButton", {
		BackgroundColor3 = C.PANEL,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = C.ERR,
		Text = "Clear conversation",
		LayoutOrder = nextOrder(),
	}, scroll)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, clearBtn)

	mk("TextLabel", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextWrapped = true,
		TextColor3 = C.MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Keys are stored in plain text in Studio's plugin settings on this machine. Personal use only.",
		LayoutOrder = nextOrder(),
	}, scroll)

	clearBtn.Activated:Connect(function()
		clearConversation()
		settingsPanel.Visible = false
		setStatus("Conversation cleared", false)
	end)
end

-- ═══════════════════════ 8. STORE ═══════════════════════

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
SelfTest.case("provider: 413 classifies as too-large before rate-limit", function()
	Cooling["groq:1"] = nil
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

local Store = {}
do
	local ROOT_NAME = "RoScriptPro"

	function Store.inEdit()
		return RunService:IsEdit()
	end

	-- FNV-1a 32-bit, hex. Luau has no hashing built in, and a plain h * prime
	-- overflows 2^53 for large h, so the multiply is done exactly in 16-bit halves.
	local function mul32(a, b)
		local al, ah = a % 65536, math.floor(a / 65536)
		local bl, bh = b % 65536, math.floor(b / 65536)
		return (al * bl + ((ah * bl + al * bh) % 65536) * 65536) % 4294967296
	end
	function Store.hash(s)
		local h = 2166136261
		for i = 1, #s do
			h = mul32(bit32.bxor(h, s:byte(i)), 16777619)
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
		local root, err = Store.ensure()
		if not root then
			error(err)
		end
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
		local root, err = Store.ensure()
		if not root then
			error(err)
		end
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
		local root, err = Store.ensure()
		if not root then
			error(err)
		end
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
		local root, err = Store.ensure()
		if not root then
			error(err)
		end
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

-- ═══════════════════════ 9. TOOLS ═══════════════════════

local Tools = { read = {}, write = {} }
local Refs = {} -- "#rN" -> Instance
local RefOf = setmetatable({}, { __mode = "k" }) -- Instance -> "#rN"
local refCounter = 0
local WHITELIST
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
			if type(v) ~= "table" then return nil, "expected {x,y}" end
			return Vector2.new(tonumber(v.x) or 0, tonumber(v.y) or 0)
		elseif expected == "Color3" then
			if type(v) ~= "table" then return nil, "expected {r,g,b} 0-255" end
			return Color3.fromRGB(math.clamp(tonumber(v.r) or 0, 0, 255), math.clamp(tonumber(v.g) or 0, 0, 255), math.clamp(tonumber(v.b) or 0, 0, 255))
		elseif expected == "UDim" then
			if type(v) ~= "table" then return nil, "expected {s,o}" end
			return UDim.new(tonumber(v.s) or 0, tonumber(v.o) or 0)
		elseif expected == "UDim2" then
			if type(v) ~= "table" then return nil, "expected {xs,xo,ys,yo}" end
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
	local _, e2 = Tools.decodeValue("5", "UDim2")
	assert(e2 and e2:find("expected", 1, true), "non-table for UDim2 rejected, not thrown")
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

-- ═══════════════════════ 10. AGENT ═══════════════════════

-- ═══════════════════════ 11. GOAL UI ═══════════════════════

-- ═══════════════════════ 12. BOOTSTRAP ═══════════════════════

local function historyChars()
	local n = 0
	for _, m in ipairs(history) do
		n += #m.content
	end
	return n
end

local function trimHistory()
	while #history > HISTORY_MAX_MSGS or (historyChars() > HISTORY_MAX_CHARS and #history > 1) do
		table.remove(history, 1)
	end
end

local function assembleMessages(ctx)
	local messages = { { role = "system", content = buildSystemPrompt() } }
	for i, m in ipairs(history) do
		local content = m.content
		if i == #history and m.role == "user" and ctx then
			content = content .. "\n\n" .. ctx
		end
		table.insert(messages, { role = m.role, content = content })
	end
	return messages
end

local function sendMessage(text, isRetry)
	if busyState or unloaded then
		return
	end
	if isRetry then
		text = lastPrompt
	end
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #text == 0 then
		return
	end
	if KeyStore.count() == 0 then
		UI.setStatus("Add a free API key first (Set button)", true)
		return
	end

	gen += 1
	local myGen = gen
	lastPrompt = text
	if not isRetry and inputBox then
		inputBox.Text = ""
	end

	local ctx, caption = buildContext()
	lastUserBubble = UI.addBubble("user", text, { caption = caption })
	table.insert(history, { role = "user", content = text })
	trimHistory()
	local messages = assembleMessages(ctx)

	UI.setBusy(true)
	UI.setStatus("Thinking…", false)

	-- Status closure carries the generation check: an orphaned (stopped) queue
	-- walk still yielded in RequestAsync can never write stale status.
	local function statusFn(text)
		if myGen == gen and not unloaded then
			UI.setStatus(text, false)
		end
	end

	task.spawn(function()
		local result, err = chatWithContinuation(messages, statusFn)
		if myGen ~= gen or unloaded then
			trace("stale response dropped (gen)")
			return
		end
		UI.setBusy(false)
		if result then
			table.insert(history, { role = "assistant", content = result.text })
			trimHistory()
			local opts = {}
			if result.truncated then
				opts.footer = "Response truncated."
			elseif looksLikeRefusal(result.text) then
				opts.footer = "Looks like a refusal — rephrase or hit Retry."
			end
			UI.addBubble("assistant", result.text, opts)
			UI.setStatus("Answered by " .. result.entry.m, false)
		else
			-- Remove the unanswered user turn so Retry re-adds it cleanly.
			if #history > 0 and history[#history].role == "user" then
				table.remove(history)
			end
			UI.addBubble("error", err or "unknown error", { retry = true })
			UI.setStatus(utf8Trim(err or "error", 120), true)
		end
	end)
end

local function stopCurrent()
	gen += 1 -- orphans the in-flight response; it is dropped on arrival
	UI.setBusy(false)
	UI.setStatus("Stopped — response discarded on arrival", false)
	if #history > 0 and history[#history].role == "user" then
		table.remove(history) -- don't carry an unanswered turn
	end
	if lastUserBubble then
		local cap = lastUserBubble:FindFirstChild("Caption")
		if cap then
			cap.Text = cap.Text .. "  (stopped)"
		else
			mk("TextLabel", {
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				Font = Enum.Font.Gotham,
				TextSize = 10,
				TextColor3 = C.MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "(stopped)",
				Name = "Caption",
				LayoutOrder = 99,
			}, lastUserBubble)
		end
	end
end

onSendRef = sendMessage
onStopRef = stopCurrent

-- Toolbar + widget
local toolbar = plugin:CreateToolbar("RoScript Pro")
local button = toolbar:CreateButton("RoScriptProToggle", "Toggle RoScript Pro chat", "", "RoScript")
button.ClickableWhenViewportHidden = true -- else it greys out whenever a script tab has focus

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 380, 520, 300, 350)
local okAsync, w = pcall(function()
	return plugin:CreateDockWidgetPluginGuiAsync("RoScriptProChat", widgetInfo)
end)
if not okAsync then
	w = plugin:CreateDockWidgetPluginGui("RoScriptProChat", widgetInfo)
end
w.Title = "RoScript Pro"

S.warm()
buildUI(w)

button.Click:Connect(function()
	w.Enabled = not w.Enabled
end)
w:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(w.Enabled)
end)
button:SetActive(w.Enabled)

if KeyStore.count() == 0 then
	UI.addBubble("assistant", "Welcome to RoScript Pro. Add a free Groq, OpenRouter or Cerebras API key via the Set button to start. Your Explorer selection and open script travel with each message (toggle with CTX).", nil)
end

plugin.Unloading:Connect(function()
	unloaded = true
	gen += 1
end)

trace("RoScript Pro loaded")

if DEV then
	SelfTest.run()
end
