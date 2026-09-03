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
local buildGoalView, chatView, goalView
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
	return body, panel
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
	chatView = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32) }, root)

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

	-- Chat scroll
	chatScroll = mk("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -66),
		Position = UDim2.new(0, 0, 0, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, chatView)
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
	}, chatView)
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

	buildGoalView(root)
	setGoalMode(S.get("goal_mode", false))
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

do
	function Tools.syntaxCheck(source)
		local ok, fn, err = pcall(loadstring, source)
		if not ok then return false, "could not compile: " .. tostring(fn) end
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

-- Each write tool returns a result table and never touches the recording itself (the Executor
-- owns TryBeginRecording/FinishRecording); ctx.simulated[inst] carries the source as earlier
-- calls in the same batch left it, so later calls in a batch see earlier edits.
do
	local function scriptTarget(target)
		local inst, err = Tools.resolve(target)
		if not inst then return nil, err end
		if not inst:IsA("LuaSourceContainer") then return nil, "not a script: " .. inst.ClassName end
		return inst
	end
	local function protected(inst)
		local root = Store.root()
		return (root and (inst == root or inst:IsDescendantOf(root))) or inst:IsDescendantOf(game:GetService("CoreGui"))
	end
	local function currentSource(inst, ctx)
		return (ctx and ctx.simulated and ctx.simulated[inst]) or Tools.readSource(inst)
	end
	-- compute(old) -> new | nil, err. It runs INSIDE UpdateSourceAsync's callback so the edit
	-- lands on the source the editor actually holds at write time, not on a copy read before
	-- the yield. The syntax gate runs on the computed source inside the callback too; the
	-- callback must not yield, and loadstring does not. err may be a full result table.
	local function applySource(inst, compute, ctx, tool, extraOf)
		if ctx.dryRun then
			local base = currentSource(inst, ctx)
			local new, cerr = compute(base)
			if not new then return type(cerr) == "table" and cerr or { ok = false, error = tostring(cerr) } end
			local okS, serr = Tools.syntaxCheck(new)
			if not okS then return { ok = false, error = "syntax error: " .. serr } end
			ctx.simulated[inst] = new
			return { ok = true, dry = true, newSource = new }
		end
		local landed, extra, failErr
		local ok, err = Tools.writeSource(inst, function(old)
			local new, cerr = compute(old)
			if not new then failErr = cerr; return nil, "compute rejected" end
			local okS, serr = Tools.syntaxCheck(new)
			if not okS then failErr = "syntax error: " .. serr; return nil, failErr end
			landed = new
			extra = extraOf and extraOf(old, new) or nil
			return new
		end)
		if not ok or not landed then
			if type(failErr) == "table" then return failErr end
			return { ok = false, error = failErr or err or "write failed" }
		end
		ctx.simulated[inst] = landed
		local r = { ok = true, path = inst:GetFullName(), ref = Tools.ref(inst), hash = Store.hash(landed), tool = tool }
		for k, v in pairs(extra or {}) do r[k] = v end
		return r
	end

	function Tools.write.replace_lines(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		return applySource(inst, function(old)
			if Store.hash(old) ~= tostring(args.expectHash) then
				return nil, { ok = false, error = "expectHash does not match the current source; read_script again" }
			end
			local lines = old:split("\n")
			local from, to = tonumber(args.fromLine), tonumber(args.toLine)
			if not from or not to or from % 1 ~= 0 or to % 1 ~= 0 or from < 1 or to < from or to > #lines then
				return nil, { ok = false, error = ("line range must be whole numbers within 1..%d"):format(#lines) }
			end
			local out = {}
			for i = 1, from - 1 do table.insert(out, lines[i]) end
			for _, l in ipairs(tostring(args.newText or ""):split("\n")) do table.insert(out, l) end
			for i = to + 1, #lines do table.insert(out, lines[i]) end
			return table.concat(out, "\n")
		end, ctx, "replace_lines", function()
			return { from = tonumber(args.fromLine), to = tonumber(args.toLine), newLines = select(2, tostring(args.newText or ""):gsub("\n", "")) + 1 }
		end)
	end

	function Tools.write.edit_script(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		local find, rep = tostring(args.find or ""), tostring(args.replace or "")
		if #find == 0 then return { ok = false, error = "empty find" } end
		return applySource(inst, function(old)
			local first = old:find(find, 1, true)
			if not first then
				-- nearest: best single-line match of find's first non-blank line
				local probe = find:match("([^\n]*%S[^\n]*)") or find
				local lines = old:split("\n")
				local bestI = nil
				for i, l in ipairs(lines) do if l:find(probe, 1, true) then bestI = i; break end end
				local near = {}
				if bestI then for i = math.max(1, bestI - 3), math.min(#lines, bestI + 3) do table.insert(near, i .. "\t" .. lines[i]) end end
				return nil, { ok = false, error = "find not found", nearest = table.concat(near, "\n") }
			end
			local second = old:find(find, first + #find, true)
			if second and not args.all then
				local count, pos, ln = 0, 1, {}
				while true do local s = old:find(find, pos, true); if not s then break end; count += 1; table.insert(ln, select(2, old:sub(1, s):gsub("\n", "")) + 1); pos = s + #find end
				return nil, { ok = false, error = ("find matches %d times; set all=true or make it unique"):format(count), lines = ln }
			end
			if args.all then
				return (old:gsub(find:gsub("%W", "%%%0"), (rep:gsub("%%", "%%%%"))))
			else
				return old:sub(1, first - 1) .. rep .. old:sub(first + #find)
			end
		end, ctx, "edit_script", function()
			return { find = utf8Trim(find, 400), replace = utf8Trim(rep, 400) }
		end)
	end

	function Tools.write.write_script(args, ctx)
		local inst, err = scriptTarget(args.target); if not inst then return { ok = false, error = err } end
		if protected(inst) then return { ok = false, error = "target is protected" } end
		local new = tostring(args.source or "")
		return applySource(inst, function(old) return new end, ctx, "write_script", function(old)
			return { linesChanged = Tools.lineDiffPercent(old, new), newLines = select(2, new:gsub("\n", "")) + 1 }
		end)
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
			if not okS then inst:Destroy(); return { ok = false, error = "syntax error: " .. serr } end -- never-parented scratch instance; not user content
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
			-- §5.2: ok unless nothing applied and something was rejected, so a wholly
			-- rejected call reads as a failure and the model tries a whitelisted property.
			return { ok = #applied > 0 or next(rejected) == nil, applied = applied, rejected = rejected, path = inst:GetFullName() }
		end)
		-- flatten for the single-target common case
		if type(args.targets) == "table" and #args.targets == 1 then
			local only = r.results[args.targets[1]]
			if only then return only end
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
			Store.trash(inst, ctx.planId) -- moves into the store's Trash folder; never destroys
			return { ok = true, path = path, origParent = from, trashed = true }
		end)
	end
end

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
SelfTest.case("executor: graceful failure keeps the batch, a throw rolls it back", function()
	local okRun, err = pcall(function()
		withScratch(function(f)
			local s = Instance.new("Script"); s.Name = "S"; s.Source = "print(1)"; s.Parent = f
			Goal.plan = { steps = { { n = 1, targets = { "ServerStorage.RSP_TestScratch" }, risk = "low" } } }
			Goal.steps = { { n = 1, changed = {}, writes = {}, undoLabels = {} } }
			local ps = { phase = "ACTING", step = Goal.plan.steps[1], myGen = Goal.gen, used = { calls = 0, tokens = 0 }, budget = { calls = 99, tokens = 1e9 }, consecutiveErrors = 0 }
			-- A graceful {ok=false} is reported to the model but does NOT roll the batch back (§8.3).
			local results, committed = Executor.runWriteBatch({
				{ index = 1, name = "write_script", args = { target = "ServerStorage.RSP_TestScratch.S", source = "print(2)" } },
				{ index = 2, name = "set_props", args = { targets = { "ServerStorage.RSP_TestScratch.S" }, props = { { name = "Nope", value = "1" } } } },
			}, ps)
			assert(committed == true, "a graceful failure keeps the batch")
			assert(results[1].ok and s.Source == "print(2)", "script written")
			assert(results[2].ok == false and results[2].rejected.Nope, "nothing applied means ok=false, with the reason")
			assert(#Goal.steps[1].changed == 1 and Goal.steps[1].changed[1].hashBefore ~= Goal.steps[1].changed[1].hashAfter, "one script change recorded")
			assert(#Goal.steps[1].undoLabels == 1, "one recording committed")
			-- A throw cancels the recording and refuses the rest of the batch (§8.3).
			Tools.write.__test_throw = function() error("boom") end
			local r2, c2 = Executor.runWriteBatch({
				{ index = 1, name = "write_script", args = { target = "ServerStorage.RSP_TestScratch.S", source = "print(3)" } },
				{ index = 2, name = "__test_throw", args = {} },
			}, ps)
			Tools.write.__test_throw = nil
			assert(c2 == false and s.Source == "print(2)", "the throw rolled the batch back")
			assert(r2[2].ok == false and r2[2].error:find("write crashed", 1, true), "the throwing call reports its crash")
			assert(r2[1].ok == false and r2[1].error:find("rolled back", 1, true), "its sibling is marked collateral")
			assert(#Goal.steps[1].changed == 1 and #Goal.steps[1].undoLabels == 1, "rollback truncated only this batch's bookkeeping")
		end)
	end)
	Tools.write.__test_throw = nil
	Goal.plan, Goal.steps = nil, {}
	assert(okRun, err)
end)

-- ═══════════════════════ 10. AGENT ═══════════════════════

local Agent = {}

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
local function compactConvo(convo, tools)
	local changed = false
	local ELIDED = "[result elided; call the tool again if needed]"
	while estimateTokens(convo.messages, tools, nil) > BIG_REQ_MAX do
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
	-- Every status write is generation-checked: chatOnce can call this several
	-- times per request while walking the queue, and a Stop mid-flight must not
	-- leave a stale phase on the label.
	local function say(text)
		if Agent.checkGen(ps.myGen) then
			GoalUI.setPhase(ps.phase, text)
		end
	end
	local waits = 0
	while true do
		if not Agent.checkGen(ps.myGen) then return nil, "stopped" end
		local est = estimateTokens(convo.messages, tools, convo.lastUsage)
		if est > BIG_REQ_MAX then
			compactConvo(convo, tools)
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
				say(("pacing Cerebras key #%d, %ds"):format(idx, math.ceil(gap)))
				task.wait(gap)
				if not Agent.checkGen(ps.myGen) then return nil, "stopped" end
			end
		end
		local state = { failedModels = {}, failedProviders = {} }
		local opts = { goal = true, tools = tools, temperature = GOAL_TEMPERATURE, estTokens = est, maxTokens = nil }
		local result, err = chatOnce(convo.messages, state, say, opts)
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
			if compactConvo(convo, tools) then continue end
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
			say(("waiting %ds for a key to cool"):format(math.ceil(soonest)))
			task.wait(soonest + 1)
			continue
		end
		return nil, err
	end
end

local CONTROL = { submit_plan = true, finish_step = true, write_memory = true }
local WRITE_TOOLS = { replace_lines = true, edit_script = true, write_script = true, create = true, set_props = true, move = true, trash = true }

local function decodeArgs(call)
	local ok, args = pcall(function() return HttpService:JSONDecode(call["function"].arguments or "{}") end)
	if not ok or type(args) ~= "table" then return nil, "arguments are not a JSON object" end
	return args
end

local Executor = {}
do
	-- Only these three write tools change a script's source text; only they get a
	-- "before" snapshot and a changed[] entry keyed by source hash. A set_props/move/
	-- trash call whose target happens to be a script must NOT be mistaken for a source edit.
	local SOURCE_TOOLS = { write_script = true, edit_script = true, replace_lines = true }

	function Executor.isOffTarget(inst, step)
		for _, t in ipairs(step.targets or {}) do
			local declared = Tools.resolve(t)
			if declared and (inst == declared or inst:IsDescendantOf(declared)) then return false end
		end
		return true
	end

	-- Pre-walk (no writes): simulate sources, decide prompts. Runs entirely before any
	-- recording opens, so a human decision (GoalUI.prompt, in the caller) never holds one
	-- open. Returns a list of { write, reason, inst } for calls that need a prompt.
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
			-- simulate so later calls in the batch see this one; a dryRun copy of ctx (table.clone
			-- shares ctx.simulated by reference but flips dryRun) guarantees no real write lands here
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
		if a.find then a.find = utf8Trim(a.find, 3000) end
		if a.replace then a.replace = utf8Trim(a.replace, 3000) end
		return HttpService:JSONEncode(a)
	end

	-- The one recording-gated write path. Prompts are collected and answered BEFORE
	-- TryBeginRecording, so a human decision never holds a recording open. The whole
	-- batch runs under a single recording: if any write fails, the recording is
	-- cancelled (Studio reverts everything it did) and the batch does not commit.
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
		ctx.simulated = {} -- discard the pre-walk simulation; the real run recomputes as writes commit
		local base = (step.n == 0) and "Repair" or ("Step %d"):format(step.n)
		local label = base .. (ps.batches and ps.batches > 0 and (", part " .. (ps.batches + 1)) or "")
		local rec = ChangeHistoryService:TryBeginRecording("RoScriptPro " .. label, "RoScript Pro: " .. label)
		if not rec then return refuseAll("undo unavailable, writes refused", false) end -- no recording => no write
		Goal.openRecording = { id = rec, owner = coroutine.running() }
		ps.batches = (ps.batches or 0) + 1
		local bookkeeping = Goal.steps[step.n]
		bookkeeping.beforeSources = bookkeeping.beforeSources or {}
		local changedAt, writesAt = #bookkeeping.changed, #bookkeeping.writes -- this batch's start, for a scoped rollback
		local committed = true
		local failedAt = nil
		for _, w in ipairs(writes) do
			if skip[w.index] then
				results[w.index] = { ok = false, error = "skipped by Jasper", attributable = false }
			else
				local target = w.args.target or (type(w.args.targets) == "table" and w.args.targets[1])
				local inst = target and Tools.resolve(target)
				local isSourceWrite = SOURCE_TOOLS[w.name] and inst and inst:IsA("LuaSourceContainer")
				local before = isSourceWrite and Tools.readSource(inst) or nil
				local okCall, r = pcall(Tools.write[w.name], w.args, ctx)
				if not okCall then r = { ok = false, error = "write crashed: " .. tostring(r) }; failedAt = w.index end
				-- UpdateSourceAsync (inside the pcall above) is the one bounded yield allowed
				-- inside this recording; re-check gen the moment it returns.
				if not Agent.checkGen(ps.myGen) then
					-- we opened this recording, so only we may finish it (never called twice on one id)
					ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Cancel)
					Goal.openRecording = nil
					return refuseAll("stopped", false)
				end
				results[w.index] = r
				-- No per-write log line here: a later throw in this batch rolls these writes
				-- back, so only GoalUI.logBatch at the settled return tells the truth.
				-- §8.3: only a throw (pcall failure, above) rolls the batch back. A graceful
				-- {ok=false} — a stale hash, an ambiguous find, nothing whitelisted applied —
				-- is reported to the model and the batch still commits; that outcome is meant
				-- to be read and retried, not to void sibling writes that already succeeded.
				if r.ok and isSourceWrite and before then
					local k = #bookkeeping.changed + 1
					bookkeeping.beforeSources[k] = before
					table.insert(bookkeeping.changed, { path = r.path or inst:GetFullName(), ref = Tools.ref(inst), kind = "script", hashBefore = Store.hash(before), hashAfter = r.hash or Tools.hashOf(inst), before = "before/" .. k })
				elseif r.ok and (r.created or r.moved or r.trashed or r.results or r.applied) then
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
			-- undo only THIS batch's bookkeeping; a step can span several batches and an
			-- earlier committed batch's entries must survive a later batch's rollback
			for k = #bookkeeping.changed, changedAt + 1, -1 do
				bookkeeping.beforeSources[k] = nil
				table.remove(bookkeeping.changed, k)
			end
			for k = #bookkeeping.writes, writesAt + 1, -1 do table.remove(bookkeeping.writes, k) end
			Goal.openRecording = nil
			GoalUI.logBatch(step, writes, results)
			return results, committed
		else
			ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
			table.insert(bookkeeping.undoLabels, "RoScript Pro: " .. label)
			GoalUI.log(("%s: %d write%s"):format(label, #writes, #writes == 1 and "" or "s"), "ok")
			Goal.openRecording = nil
			GoalUI.logBatch(step, writes, results)
			return results, committed
		end
	end
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
	local anyOk, anyFail, allAttributable = false, false, true
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
			if control then
				pending[i] = { ok = false, error = "only one control call per turn; " .. name .. " ignored", attributable = false }
			else
				control = { name = name, args = args, index = i }
			end
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
		if r.ok then
			anyOk = true
		elseif not CONTROL[c["function"].name] then
			anyFail = true
			if r.attributable == false then
				allAttributable = false
			end
		end
		results[i] = { id = c.id, content = HttpService:JSONEncode(r) }
	end
	if anyFail and not anyOk and allAttributable then ps.consecutiveErrors += 1 else ps.consecutiveErrors = 0 end
	return results, control
end

-- Shared default so all five `S.get("goal_focus", ...)` call sites (below and
-- in section 11) agree on what "no setting yet" means; declared before
-- buildGoalUserBlock, its earliest use site in source order.
local DEFAULT_FOCUS = { bugs = true, quality = true }

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
	if S.get("goal_focus", DEFAULT_FOCUS).bugs then
		local o = Tools.read.read_output({ count = 40 })
		if o.ok and #o.lines > 0 then table.insert(parts, "=== RECENT OUTPUT ERRORS ===\n" .. table.concat(o.lines, "\n")) end
	end
	local idx = Tools.read.index({ path = "game", depth = 1 })
	table.insert(parts, "=== TOP-LEVEL INDEX ===\n" .. (idx.ok and idx.text or ""))
	table.insert(parts, "=== PHASE ===\n" .. phaseInstruction)
	return table.concat(parts, "\n\n")
end

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
	local f = S.get("goal_focus", DEFAULT_FOCUS)
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
		-- Build the flattened before/k sources in the SAME pass, over the SAME sorted order
		-- (record.steps, ascending n), that rewrites ch.before: each step's own beforeSources
		-- map is read using the ORIGINAL per-step index parsed out of ch.before (Executor.
		-- runWriteBatch numbers beforeSources/changed[].before locally per step, restarting at
		-- 1 for every step), and only THEN is ch.before rewritten to the new global index. A
		-- second, independently-ordered pass (e.g. pairs(Goal.steps) for one loop and the
		-- sorted record.steps array for the other, as a plain flatten-then-rekey would do)
		-- could pair one script's ch.before with a DIFFERENT step's source text whenever the
		-- two orders disagreed, and Revert would then silently overwrite the wrong script with
		-- the wrong old source.
		local beforeSources, k = {}, 0
		for _, st in ipairs(record.steps) do
			local b = Goal.steps[st.n]
			for _, ch in ipairs(st.changed or {}) do
				if ch.before then
					k += 1
					beforeSources[k] = (b and b.beforeSources and b.beforeSources[tonumber(ch.before:match("before/(%d+)"))]) or ""
					ch.before = "before/" .. k
				end
			end
		end
		local ok, err = Store.withRecording("record", function()
			Store.writeMemory(facts, newNotes)
			Store.writeManifest(buildManifest())
			Store.writePlan(record, beforeSources)
			Store.applyCaps()
		end)
		if not ok then
			GoalUI.log("record NOT written: " .. tostring(err) .. " — the game changes stand, but this cycle was not saved", "error")
			Goal.phase = "IDLE"
			GoalUI.setBusy(false)
			GoalUI.setPhase("IDLE", "record failed")
			GoalUI.refreshPlans()
			return
		end
		Goal.phase = "IDLE"
		GoalUI.setBusy(false)
		GoalUI.setPhase("IDLE", record.id .. " · " .. record.status)
		GoalUI.showCard("result", record)
		GoalUI.refreshPlans()
	end)
end

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
							local okW, wErr = Tools.writeSource(inst, function() return src end)
							if okW then
								table.insert(report.restored, ch.path)
							else
								table.insert(report.skipped, ch.path .. " (write failed: " .. tostring(wErr) .. ")")
							end
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
					for _, it in ipairs(Store.trashItems()) do
						local parent, name = it:GetAttribute("RSP_OrigParent"), it:GetAttribute("RSP_OrigName")
						if it:GetAttribute("RSP_Plan") == id and parent and name and (parent .. "." .. name) == ch.path then
							item = it
							break
						end
					end
					local target = item or inst
					local parent = ch.origParent and walkPath(ch.origParent)
					if target and parent then target.Parent = parent; table.insert(report.restored, ch.path) else table.insert(report.skipped, ch.path .. " (origin missing)") end
				else
					table.insert(report.skipped, tostring(ch.path) .. " (no longer present)")
				end
			end
		end
	end)
	if not ok then return false, { error = werr } end
	return true, report
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
	Agent.record("cancelled") -- write_memory is skipped for a cancelled status; see Agent.record
end

function Agent.stop()
	Goal.gen += 1
	local rec = Goal.openRecording
	if rec and rec.owner ~= coroutine.running() then
		-- the owning batch coroutine cancels at its next gen check (§8.3); nothing to do here
	end
	if Goal.verifyConn then Goal.verifyConn:Disconnect(); Goal.verifyConn = nil end
	GoalUI.setBusy(false)
	if Goal.phase == "ACTING" or Goal.phase == "REPAIRING" then
		for _, b in pairs(Goal.steps) do
			if b.status == "running" then
				b.status, b.outcome = "stopped", "stopped"
			end
		end
	end
	if Goal.phase == "PLANNING" or Goal.phase == "AWAITING_APPROVAL" then
		Goal.phase = "IDLE" -- a Stop before submit_plan writes no record
		GoalUI.setPhase("IDLE", "stopped")
	elseif Goal.phase ~= "IDLE" then
		Goal.phase = "RECORDING"
		Agent.record("stopped")
	end
end

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
	step.baseDetail = step.baseDetail or step.detail
	step.detail = step.baseDetail .. "\n[previous attempt failed: " .. utf8Trim(prev, 300) .. "]"
	for k = n + 1, #Goal.plan.steps do if Goal.steps[k] and Goal.steps[k].status == "skipped" and Goal.steps[k].outcome:find("not run", 1, true) then Goal.steps[k] = nil end end
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
		root.Plans["Plan_900_revert-test"]:Destroy()
	end)
end)

-- ═══════════════════════ 11. GOAL UI ═══════════════════════

local goalBox, goalScroll, planButton, phaseLabel, stopGoalButton, plansButton, trashButton
-- showPlansView/showTrashView are forward-declared here (not `local function` at their
-- definition site below) because buildGoalView's button row, which comes first in source
-- order, must close over the same upvalue: a bare local-function declaration textually
-- after buildGoalView would leave that name unresolved to a global at the point the button
-- row closures compile, and clicking Plans/Trash would fail with "attempt to call a nil
-- value" the first time, before either function's own local ever came into scope.
local showPlansView, showTrashView
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

buildGoalView = function(root)
	goalView = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32), Visible = false }, root)
	goalBox = mk("TextBox", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, -16, 0, 60), Position = UDim2.new(0, 8, 0, 8), Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, MultiLine = true, ClearTextOnFocus = false, PlaceholderText = "Describe the goal… or leave empty and press Plan next", PlaceholderColor3 = C.MUTED, Text = "" }, goalView)
	mk("UICorner", { CornerRadius = UDim.new(0, 4) }, goalBox)
	local chips = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0, 74) }, goalView)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, chips)
	local focus = S.get("goal_focus", DEFAULT_FOCUS)
	for _, id in ipairs(FOCUS_IDS) do
		local on = focus[id] == true
		local b = mk("TextButton", { BackgroundColor3 = on and C.ACCENT or C.PANEL2, Size = UDim2.new(0, 66, 1, 0), Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = C.TEXT, Text = FOCUS_LABELS[id], AutoButtonColor = false }, chips)
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
		b.MouseEnter:Connect(function() b.BackgroundColor3 = C.ACCENT end)
		b.MouseLeave:Connect(function()
			local f2 = S.get("goal_focus", DEFAULT_FOCUS)
			b.BackgroundColor3 = f2[id] and C.ACCENT or C.PANEL2
		end)
		b.MouseButton1Click:Connect(function()
			local f = table.clone(S.get("goal_focus", DEFAULT_FOCUS))
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
	phaseLabel = mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -320, 1, 0), Position = UDim2.new(0, 152, 0, 0), Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = C.MUTED, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Text = "idle" }, row)
	plansButton = button("Plans", row, UDim2.new(0, 70, 1, 0), UDim2.new(1, -150, 0, 0), function() showPlansView(0) end)
	trashButton = button("Trash", row, UDim2.new(0, 70, 1, 0), UDim2.new(1, -74, 0, 0), showTrashView)
	goalScroll = mk("ScrollingFrame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -134), Position = UDim2.new(0, 0, 0, 132), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6 }, goalView)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, goalScroll)
	mk("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, goalScroll)
end

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
		GoalUI.view(("Step %d writes"):format(step.n), table.concat(lines, "\n"))
	end)
end
-- Blocking prompt: returns "allow" | "skip" | "stop". Runs in the calling coroutine (a batch, before its recording opens).
GoalUI.prompt = function(kind, payload)
	local answer = nil
	local _, panel = openModalPanel(payload.title or kind)
	local body = mk("ScrollingFrame", { BackgroundColor3 = C.CODEBG, Size = UDim2.new(1, -16, 1, -80), Position = UDim2.new(0, 8, 0, 34), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6 }, panel)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, body)
	for i, chunk in ipairs(chunkText(payload.text or "")) do
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Code, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, RichText = true, Text = escapeRich(chunk), LayoutOrder = i }, body)
	end
	button("Allow", panel, UDim2.new(0, 80, 0, 26), UDim2.new(0, 8, 1, -34), function() answer = "allow" end)
	button("Skip this call", panel, UDim2.new(0, 100, 0, 26), UDim2.new(0, 96, 1, -34), function() answer = "skip" end)
	button("Stop plan", panel, UDim2.new(0, 80, 0, 26), UDim2.new(1, -88, 1, -34), function() answer = "stop" end)
	while answer == nil and widgetAlive() do task.wait(0.05) end
	closeModal()
	return answer or "stop"
end
-- Read-only modal: no decision to make, just a Close button. Every "View" affordance
-- uses this; GoalUI.prompt is only for a write that is waiting on an answer.
GoalUI.view = function(title, text)
	local _, panel = openModalPanel(title)
	local body = mk("ScrollingFrame", { BackgroundColor3 = C.CODEBG, Size = UDim2.new(1, -16, 1, -80), Position = UDim2.new(0, 8, 0, 34), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6 }, panel)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, body)
	for i, chunk in ipairs(chunkText(text or "")) do
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Code, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, RichText = true, Text = escapeRich(chunk), LayoutOrder = i }, body)
	end
	button("Close", panel, UDim2.new(0, 70, 0, 26), UDim2.new(0, 8, 1, -34), closeModal)
end

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
		box.MouseEnter:Connect(function() box.BackgroundColor3 = C.ACCENT end)
		box.MouseLeave:Connect(function() box.BackgroundColor3 = s.included and C.ACCENT or C.PANEL end)
		box.MouseButton1Click:Connect(function()
			s.included = not s.included
			box.BackgroundColor3 = s.included and C.ACCENT or C.PANEL
			local any = false
			for _, st in ipairs(plan.steps) do any = any or st.included end
			local ab = f:FindFirstChild("Approve", true)
			if ab then ab.Active = any; ab.TextColor3 = any and C.TEXT or C.MUTED end
		end)
		mk("Frame", { BackgroundColor3 = RISK_COLOR[s.risk], Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, 26, 0, 8) }, row)
		local t = mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -110, 1, 0), Position = UDim2.new(0, 40, 0, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("%d. %s  [%s]  %s"):format(s.n, s.title, s.action, table.concat(s.targets, ", ")) }, row)
		button("View", row, UDim2.new(0, 44, 0, 18), UDim2.new(1, -50, 0, 3), function()
			GoalUI.view(("Step %d"):format(s.n), s.detail .. "\n\nTargets:\n" .. table.concat(s.targets, "\n"))
		end)
	end
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 99 }, f)
	local approve = button("Approve", bar, UDim2.new(0, 80, 1, 0), UDim2.new(0, 0, 0, 0), function()
		if Goal.phase ~= "AWAITING_APPROVAL" then return end
		goalBox.Text = ""
		Agent.approve() -- Task 8
	end)
	approve.Name = "Approve"
	button("Revise", bar, UDim2.new(0, 70, 1, 0), UDim2.new(0, 86, 0, 0), function()
		local note = nil
		local _, panel = openModalPanel("Revision note")
		local box = mk("TextBox", { BackgroundColor3 = C.CODEBG, Size = UDim2.new(1, -16, 0, 80), Position = UDim2.new(0, 8, 0, 34), Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.TEXT, TextWrapped = true, MultiLine = true, ClearTextOnFocus = false, Text = "" }, panel)
		button("Send", panel, UDim2.new(0, 70, 0, 26), UDim2.new(0, 8, 0, 122), function() note = box.Text end)
		while note == nil and widgetAlive() do task.wait(0.05) end
		closeModal()
		if note and #note > 0 then Agent.revise(note) end
	end)
	button("Cancel", bar, UDim2.new(0, 70, 1, 0), UDim2.new(0, 162, 0, 0), function() f:Destroy(); Agent.cancel() end)
end
local function showFailureCard(step)
	local old = goalScroll:FindFirstChild("FailureCard"); if old then old:Destroy() end
	local f = card(("Step %d failed"):format(step.n)); f.Name = "FailureCard"
	label(f, Goal.steps[step.n].outcome or "", C.ERR, 1)
	local bar = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 2 }, f)
	button("Retry step", bar, UDim2.new(0, 90, 1, 0), UDim2.new(0, 0, 0, 0), function() f:Destroy(); Agent.retryStep(step.n) end)
	button("Continue from next", bar, UDim2.new(0, 130, 1, 0), UDim2.new(0, 96, 0, 0), function() f:Destroy(); Agent.continueFrom(step.n) end)
	button("Stop", bar, UDim2.new(0, 60, 1, 0), UDim2.new(0, 232, 0, 0), function() f:Destroy(); Agent.stop() end)
end

local function showResultCard(rec)
	local old = goalScroll:FindFirstChild("ResultCard"); if old then old:Destroy() end
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
		GoalUI.view(rec.id, rec.summary .. "\n\n" .. HttpService:JSONEncode(rec))
	end)
end

showPlansView = function(offset)
	for _, c in ipairs(goalScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
	local page, total = Store.listPlans(offset)
	local f = card(("Plans %d–%d of %d"):format(offset + 1, offset + #page, total)); f.Name = "PlansView"
	for i, p in ipairs(page) do
		local row = mk("Frame", { BackgroundColor3 = C.PANEL2, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = i }, f)
		mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -150, 1, 0), Position = UDim2.new(0, 6, 0, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ("%s · %s · %s"):format(p.id, p.status, p.goal) }, row)
		button("Open", row, UDim2.new(0, 44, 0, 18), UDim2.new(1, -140, 0, 2), function()
			local rec = Store.readPlan(p.id)
			GoalUI.view(p.id, rec and (rec.summary .. "\n\n" .. HttpService:JSONEncode(rec)) or "unreadable record")
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

showTrashView = function()
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

GoalUI.showCard = function(kind, data)
	if kind == "plan" then showPlanCard(data)
	elseif kind == "failure" then showFailureCard(data.step)
	elseif kind == "result" then showResultCard(data) end
end

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
ChangeHistoryService.OnUndo:Connect(GoalUI.refreshPlans)
ChangeHistoryService.OnRedo:Connect(GoalUI.refreshPlans)
GoalUI.refreshPlans()

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
	Goal.gen += 1
	if Goal.verifyConn then Goal.verifyConn:Disconnect() end
	if Goal.openRecording then
		pcall(function() ChangeHistoryService:FinishRecording(Goal.openRecording.id, Enum.FinishRecordingOperation.Cancel) end)
	end
	Tools.clearRefs()
end)

trace("RoScript Pro loaded")

if DEV then
	SelfTest.run()
end
