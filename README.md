# 🎮 RoScript AI Pro

**A free, single-file AI coding assistant for Roblox, Unity, and Unreal game development — no backend, no signup, no cost.**

RoScript AI Pro runs entirely in your browser. Paste in your own free API keys from Groq, OpenRouter, and Cerebras, and get a fast, resilient AI coding assistant with automatic multi-provider fallback, deep reasoning, self-checked code, image generation, and live web search — all for **$0/month**.

<p align="center">
  <img src="https://img.shields.io/badge/cost-%240%2Fmonth-brightgreen" alt="Free">
  <img src="https://img.shields.io/badge/backend-none-blue" alt="No backend">
  <img src="https://img.shields.io/badge/install-single%20HTML%20file-orange" alt="Single file">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT License">
</p>

---

## Why this exists

Every good AI coding assistant costs $20/month or requires a server you have to run and pay for. RoScript AI Pro doesn't. It's one `.html` file that runs 100% client-side and talks directly to free-tier AI APIs from your browser. Open the file, drop in a few free API keys, and you have a coding assistant that rivals paid tools — with **zero infrastructure, zero cost, and zero data going through a middleman server.**

## ✨ Features

### 🔄 Multi-provider auto-fallback with key stacking
Add multiple API keys per provider (Groq, OpenRouter, Cerebras). When one key hits a rate limit or a provider goes down, RoScript instantly rotates to the next available key or provider — automatically, mid-response, without losing context. Stack 5 free keys per provider and effectively multiply your daily limits.

### 🧠 Deep Think mode (always on)
Every response — even a one-line fix — runs through maximum reasoning effort before any code is written: restate requirements → trace the logic line-by-line → check for nil/null cases, off-by-ones, and framework-specific pitfalls → **then** write the code.

### 🧪 Sandbox self-check
Generated code is automatically tested before you ever see it:
- **Static analysis** (instant, free) — bracket/quote balance, structural block matching, real JS/JSON parsing
- **AI self-review** — a second, independent model re-reads the code hunting specifically for logic bugs, then auto-corrects anything it finds — before the code is shown to you

You'll see a `🧪✓ verified` or `🧪🔧 auto-fixed` badge on every substantial code block.

### ♾️ Practically unlimited response length
Responses can grow to thousands of lines. If a provider cuts off mid-generation, RoScript automatically continues the response using **any other available key or provider** — not just the one that started it — so a single rate-limited key never truncates your code.

### 🌐 Live web search + URL reading
Connect a free Tavily key and the AI can search the web for current docs, then cite its sources. Paste any URL (blog post, doc page, even a YouTube link) and the AI reads and understands it as context — no separate step needed.

### 🎨 Image generation
Type `/image a dark fantasy sword icon` or click the 🎨 button. Uses Hugging Face's FLUX.1-schnell if you add a key, with automatic fallback to Pollinations.ai (no key required, completely free).

### 📄 Claude-style file cards
Long code blocks render as a clickable file card with a smart, content-aware filename — not a wall of code cluttering the chat. Click to open a side panel with the full file, copy, and download buttons.

### 💡 11 built-in domain skills
Toggle specialized knowledge packs on/off: DataStore Mastery, Anti-Exploit Shield, Remote Architecture, Combat Systems, UI & Tweening (Roblox) · Unity C# Patterns · Clean Code, Debug Strategies, Algorithm Patterns, Design Patterns (General) · Security Tester. Add your own custom skills too.

### 📋 Full transparency
Type `/logs` any time to see a complete request log — every provider, model, key, and status (success, rate-limited, timed out, refused) for the current session. Nothing is hidden.

### 🔒 Privacy by design
Your API keys and chat history live only in your browser's `localStorage`. Nothing is sent to any server except the AI providers you configure, directly from your browser.

---

## 🚀 Quick Start

1. **Download** [`roblox-lua-assistant.html`](./roblox-lua-assistant.html) (or clone this repo)
2. **Open it** in any modern browser — double-click, or drag it into a browser tab
3. **Get free API keys** (2 minutes, no credit card required for any of them):

| Provider | Get a free key | Free tier |
|---|---|---|
| **Groq** *(required)* | [console.groq.com/keys](https://console.groq.com/keys) | 6,000 req/day, 30 req/min per key |
| **OpenRouter** *(recommended)* | [openrouter.ai/keys](https://openrouter.ai/keys) | Free models, no hard daily cap |
| **Cerebras** *(recommended)* | [cloud.cerebras.ai](https://cloud.cerebras.ai) | 30 req/min, ultra-fast inference |
| Tavily *(optional — enables web search)* | [tavily.com](https://tavily.com) | 1,000 searches/month |
| Hugging Face *(optional — better image gen)* | [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) | Free tier |

4. **Paste your keys** into the Keys panel at the top of the app — you can add multiple keys per provider to stack your limits
5. **Start chatting.** That's it — no build step, no install, no account.

> 💡 **Tip:** You only *need* a Groq key to get started. Add OpenRouter and Cerebras keys for automatic fallback so you're never blocked by a single provider's rate limit.

---

## 🖥️ How it works

RoScript AI Pro is a single HTML file with all CSS and JavaScript inline — there's no build process, no `npm install`, no server. Your browser makes direct HTTPS requests to each AI provider's API using the keys you provide. The app is essentially a smart routing layer that:

1. Picks the best available model for your request (simple question vs. complex/code-heavy)
2. Tries your keys in order across Groq → OpenRouter → Cerebras
3. Detects rate limits, invalid keys, and dead models instantly, and reroutes automatically
4. Streams the response token-by-token as it's generated
5. Runs the self-check sandbox pass on any generated code
6. Keeps going — via key rotation — if the response needs to be longer than one call allows

Because it's just static HTML/JS, you can also host it anywhere: GitHub Pages, Netlify, Vercel, or just keep it as a local file on your desktop.

---

## Goal Mode

The Roblox Studio plugin (`studio-plugin/RoScriptPro.lua`) — a separate, single-file companion to the browser app above, installed straight into Studio — adds a second mode next to its chat assistant: Goal Mode, switched on with the Chat|Goal toggle in the plugin's top bar.

Set a goal in plain English, review the plan it comes back with and approve it (or revise the note and ask again, or cancel), and it acts on your project step by step. When the approved steps are done it can verify against how your game actually runs, then it records what happened and is ready to plan again — carrying forward what it learned instead of making you re-explain your project every time.

The cycle, by name: **Idle → Planning → Awaiting approval → Acting → Verifying → Repairing (only if Verifying finds trouble) → Recording**, then back to Idle.

Everything Goal Mode touches lives in one place, `ServerStorage.RoScriptPro`, kept separate from your actual game tree:
- **Memory** — the facts it has gathered about your project, plus a running Notes summary (Game / Conventions / Decisions / Known issues) it rewrites at the end of every cycle, so the next goal starts already knowing your project.
- **Manifest** — a hash of every script it has touched, so it can tell what's changed since it last looked.
- **Plans** — one record per completed cycle: the goal, the steps, what changed, and enough detail to revert it later.
- **Trash** — anything a plan moved aside or replaced, kept here instead of being deleted.

**Revert** a plan from the Plans view: it restores every script the plan touched, as long as you haven't hand-edited it since (anything you've touched is skipped and listed, never overwritten), and moves anything the plan created into Trash rather than deleting it.

Two safety facts worth knowing:
- The model never destroys anything. Removals go to Trash first, and anything there can be restored — Trash keeps its newest 25 items for up to 14 days, after which the oldest are cleared automatically.
- The plugin never starts or stops a playtest for you. Verifying watches the Run button you press yourself (F8); the model reads what happens while it runs, but pressing Run and Stop stays entirely in your hands.

---

## 📦 Hosting it yourself (optional)

Since it's a static file, you can deploy it for free in under a minute:

**GitHub Pages**
```bash
# In your forked repo settings → Pages → deploy from main branch
# Then visit: https://<your-username>.github.io/<repo-name>/roblox-lua-assistant.html
```

**Netlify / Vercel** — drag and drop the `.html` file into their dashboard, or connect the repo.

---

## ⚠️ Notes & limitations

- This project uses **free-tier third-party APIs**. Rate limits, model availability, and free-tier terms are controlled by Groq, OpenRouter, Cerebras, Tavily, and Hugging Face — not by this project — and can change at any time.
- Static code analysis (Layer 1 of the sandbox) covers JS/JSON with real parsing; other languages (Lua, C#, C++) use structural heuristics, not full compilation — the AI self-review layer (Layer 2) is what catches logic bugs.
- Your API keys are stored in browser `localStorage`, unencrypted. Don't use this on a shared/public computer with keys you care about, and don't commit your keys anywhere.
- This is a community tool built for personal/hobbyist use with free-tier keys — it is not affiliated with Groq, OpenRouter, Cerebras, Roblox, Unity, or Unreal.

---

## 🤝 Contributing

Issues and PRs welcome. A few ideas if you want to contribute:
- Additional domain skills (Godot, GameMaker, etc.)
- More provider integrations
- UI/UX polish
- Better static-analysis heuristics for more languages

---

## 📄 License

MIT — do whatever you want with it. If you build something cool on top of it, a shoutout is appreciated but not required.

---

<p align="center">Built for the game dev community. If this saved you $20/month, consider starring the repo ⭐</p>
