# Claude Godot Plugin

A Godot 4 editor plugin that embeds [Claude Code](https://claude.ai/code) directly into the Godot editor. Ask Claude questions, fix errors, and get context-aware assistance without ever leaving the editor.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [First-Time Setup](#first-time-setup)
- [Using the Chat Panel](#using-the-chat-panel)
- [Context Injection](#context-injection)
- [Settings](#settings)
- [Fix With Claude (Debugger Errors)](#fix-with-claude-debugger-errors)
- [Send To Claude (Output Log)](#send-to-claude-output-log)
- [Ask Claude About This (Scene Tree)](#ask-claude-about-this-scene-tree)
- [Godot Doctor Integration](#godot-doctor-integration)
- [Chat History and Sessions](#chat-history-and-sessions)
- [Exporting Chat](#exporting-chat)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)

---

## Features

- **Docked chat panel** — talk to Claude without leaving the editor
- **Editor context injection** — Claude automatically knows your current scene, selected nodes, open scripts, exports, autoloads, and more
- **Fix With Claude** — one click sends Debugger errors directly to Claude
- **Send To Claude** — one click sends the Output log to Claude
- **Scene tree right-click** — right-click any node and choose "Ask Claude about this"
- **Streaming responses** — see Claude's reply as it types (Linux/macOS)
- **Persistent sessions** — conversations resume across editor restarts
- **Chat history** — last 100 messages restored when you reopen the editor
- **Model selection** — choose between Sonnet, Opus, and Haiku
- **One-click install** — if Claude Code isn't installed, the panel installs it for you
- **Godot Doctor integration** — optional auto-validation and auto-fix workflow
- **Cross-platform** — Linux, macOS, and Windows

---

## Requirements

- **Godot 4.x** (4.3+ recommended for full context menu support)
- **[Claude Code CLI](https://claude.ai/code)** — the `claude` command must be available in your PATH
  - Requires **[Node.js](https://nodejs.org)** (for `npm install`)
  - Requires a free **[Anthropic account](https://console.anthropic.com)**

---

## Installation

### Step 1 — Copy the addon

Copy the `addons/claude_godot/` folder into your Godot project's `addons/` directory:

```
your_project/
└── addons/
    └── claude_godot/       ← copy this folder here
        ├── plugin.cfg
        ├── plugin.gd
        ├── claude_panel.gd
        ├── claude_runner.gd
        ├── context_builder.gd
        ├── claude_context_menu.gd
        └── godot_doctor_bridge.gd
```

You can also use a symlink if you are developing the plugin itself:

```bash
ln -s /path/to/Claude-Godot/addons/claude_godot /path/to/your_project/addons/claude_godot
```

### Step 2 — Enable the plugin

Open your project in Godot, then:

**Project → Project Settings → Plugins**

Find **Claude Godot** and click the **Enable** checkbox.

A **Claude** panel will appear in the top-right dock area. If Claude Code is not installed, an install screen will appear instead.

---

## First-Time Setup

### Installing Claude Code

If the Claude Code CLI is not installed, the panel shows an install screen.

1. Make sure **Node.js** is installed (`node --version` should work in a terminal). If not, download it from [nodejs.org](https://nodejs.org).
2. Click **"Install Claude Code"** in the panel. This runs:
   ```
   npm install -g @anthropic-ai/claude-code
   ```
3. On Linux/macOS, if you get a permission error, check **"Use sudo"** before clicking Install.
4. After installation completes, the **"Authenticate"** button appears.

### Authenticating

Click **"Authenticate"** to open a terminal window running `claude auth login`. Follow the prompts to connect your Anthropic account.

After authentication, restart Godot (or disable and re-enable the plugin) and the chat panel will appear.

---

## Using the Chat Panel

The Claude panel docks in the **top-right** of the editor.

### Sending a message

Type in the input box at the bottom and press **Enter** to send. Use **Shift+Enter** to insert a line break without sending.

### Toolbar buttons

| Button | Action |
|--------|--------|
| **New** | Start a fresh conversation — clears history and session ID |
| **Clear** | Clear the chat display only (history is preserved) |
| **Export** | Save the conversation as a Markdown file |
| **⚙** | Open the Settings dialog |

### While Claude is responding

- A thinking indicator animates in the chat with a rotating status message (e.g. "Reticulating Splines...", "Cogitating...")
- A **Cancel** button appears — click it to abort the current request
- On Linux/macOS, responses stream in progressively as Claude writes them
- On Windows, the full response appears when complete

---

## Context Injection

Claude knows what you are working on. When **"Include context"** is enabled (the default), every message includes a system prompt describing your current editor state.

### Context panel

Below the toolbar is a collapsible **Context** section. Click the header to expand it.

- **Status line** — shows your current scene and selection at a glance
- **Include context** checkbox — master toggle for all context injection
- **Files** checkbox — allows Claude to read files in your project directory (see below)
- **Preview** button — opens a dialog showing the exact prompt being sent to Claude

### What context is included

Which sections are included is controlled in the **Settings** dialog (gear icon). Available sections:

| Section | Default | What it includes |
|---------|---------|-----------------|
| Scene tree | On | Scene file path, root node name and type, child nodes (configurable depth) |
| Selected node | On | Name, class, script path, position, groups |
| Open scripts | On | Paths of scripts currently open in the script editor |
| Export variables | On | `@export` variables on the selected node and their current values |
| Autoloads | On | All project singleton names and paths |
| AnimationPlayer clips | On | Animation names found on the selected node |
| Script source | Off | Full source code of the selected node's script (capped at 8000 characters) |
| Input map | Off | Custom input action names |
| Node signals | Off | Custom signals and active connections on the selected node |
| Open scenes | Off | Paths of all currently open scenes |
| Error log | Off | Recent errors/warnings from the Godot log |

### Scene tree depth

In Settings, **"Scene tree depth"** controls how many levels of children are included (1–5). Deeper trees give Claude more context but use more tokens.

### File access mode

When the **Files** checkbox is enabled:
- Claude is invoked with `--add-dir <project_dir>` and `--dangerously-skip-permissions`
- Claude can read any file in your project directory
- Use this when asking Claude to help with specific scripts or assets

---

## Settings

Click the **⚙** button to open the Settings dialog.

| Setting | Description |
|---------|-------------|
| **Model** | Choose between Sonnet 4.6 (default, best balance), Opus 4.6 (most capable), or Haiku 4.5 (fastest, cheapest) |
| **Custom prompt** | Text prepended to every message — describe your project conventions, architecture, or recurring context |
| **Context section toggles** | Enable/disable each context section individually (see table above) |
| **Scene tree depth** | How many levels deep to include in the scene tree (1–5) |
| **Error log lines** | How many error/warning lines to include when the error log section is on (5–100) |
| **Godot Doctor** | Auto-validation and auto-send settings (see [Godot Doctor Integration](#godot-doctor-integration)) |

Settings are saved per-project in Godot's editor metadata and persist across editor restarts.

### Custom prompt tips

The custom prompt is a good place to tell Claude things that never change about your project:

```
This is a 2D platformer. The player uses PlayerController.gd (singleton). 
Physics is all CharacterBody2D. Animations use snake_case names.
All game events go through EventBus.gd.
```

---

## Fix With Claude (Debugger Errors)

When script errors appear in the Debugger's **Errors** tab, a **"Fix With Claude"** button appears in that tab's toolbar next to the Clear button.

Clicking it:
1. Collects all errors currently listed in the Errors tab
2. Opens the Claude panel (brings it to focus)
3. Sends a message asking Claude to help fix the errors, with the full error text included

Claude responds with an explanation and suggested fixes, with full awareness of your current scene and selected node.

---

## Send To Claude (Output Log)

A **"Send To Claude"** button appears in the **Output** tab's toolbar next to the Clear button.

Clicking it:
1. Captures all text currently in the Output panel
2. Opens the Claude panel (brings it to focus)
3. Sends the output to Claude asking for help understanding any errors or warnings

This is useful for `print()` debug output, plugin errors, and anything else that appears in the Output panel but not the Errors tab.

---

## Ask Claude About This (Scene Tree)

In Godot 4.3 and later, right-clicking any node in the Scene tree shows an **"Ask Claude about this"** option in the context menu.

Clicking it sends a message asking Claude to explain the selected node, using your current context settings. For example, right-clicking a `CharacterBody2D` node named "Player" sends:

> Tell me about the Player node (CharacterBody2D).

Claude responds with full context awareness — it already knows the node's script, exports, animations, and signals.

---

## Godot Doctor Integration

[Godot Doctor](https://github.com/godotengine/godot) is a separate Godot plugin that validates your project against best practices. If it is installed, the Claude plugin adds optional integration.

### Setup

1. Install Godot Doctor separately (`addons/godot_doctor/`)
2. Enable it in Project Settings → Plugins
3. In the Claude Settings dialog, the **Godot Doctor** section will show "Installed"

### Features

| Feature | Setting | Description |
|---------|---------|-------------|
| **Fix with Claude** button | Always shown | A button added to the Godot Doctor dock that sends current issues to Claude |
| **Auto-validate** | "Auto-validate after each response" | After Claude responds, Godot Doctor automatically re-validates the scene |
| **Auto-send issues** | "Auto-send issues to Claude" | If auto-validation finds new issues, they are automatically sent to Claude for the next fix iteration |

The auto-send loop lets Claude iteratively fix project issues: Claude makes a change → Godot Doctor validates → issues are sent back → Claude fixes again.

---

## Chat History and Sessions

### Sessions

Claude Code maintains conversation context using a session ID. The session ID is saved in your editor metadata and automatically reused when you send the next message, so Claude remembers what you discussed.

- **New** clears the session ID, starting a completely fresh conversation
- Sessions survive editor restarts — you can pick up a conversation the next day

### Chat history

The last 100 messages are saved to:

```
{user_data_dir}/claude_godot/history_{project_hash}.json
```

Each project gets its own history file. On editor restart, the chat display is restored from this file so you can see what was discussed.

- **New** clears history and starts fresh
- **Clear** clears only the visual display — history is preserved and will be restored on next restart
- History is distinct from the Claude session: history is what you *see*, the session is what Claude *remembers*

---

## Exporting Chat

Click **Export** to save the current conversation to:

```
res://claude_chat_YYYY-MM-DD_HH-MM.md
```

The file is Markdown-formatted with `## You`, `## Claude`, and `## Error` section headers. This is useful for keeping AI-assisted design decisions in version control alongside your code.

---

## How It Works

### Architecture overview

| File | Role |
|------|------|
| `plugin.gd` | Editor plugin entry point — creates the panel, injects toolbar buttons, connects to Godot Doctor |
| `claude_panel.gd` | The chat UI — all built in code (no `.tscn`), handles state, history, settings, streaming display |
| `claude_runner.gd` | Executes the `claude` CLI in a background thread; parses the JSON stream; emits signals |
| `context_builder.gd` | Static methods that read editor state and assemble the system prompt string |
| `claude_context_menu.gd` | Adds "Ask Claude about this" to the scene tree right-click menu |
| `godot_doctor_bridge.gd` | Optional bridge to Godot Doctor — discovers its dock, injects a button, collects issues |

### CLI invocation

The runner builds a command like this:

```
claude --print --output-format stream-json --verbose
       [--model MODEL_ID]
       [--append-system-prompt "...editor context..."]
       [--add-dir /path/to/project --dangerously-skip-permissions]
       [--resume SESSION_UUID]
       "Your message here"
```

On Windows this is wrapped as `cmd.exe /c claude ...`.

### Streaming (Linux/macOS)

On Linux and macOS, the plugin uses a temporary shell script and polls a temp file to read output incrementally. Each JSON event from the stream is parsed as it arrives, and text deltas are appended to the chat bubble in real time.

On Windows, `OS.execute()` is used in blocking mode — the response appears all at once when complete.

### Thread safety

All CLI execution happens in a background `Thread`. Any UI update from that thread uses `call_deferred()` to safely run on the main thread. The panel calls `cleanup()` before being freed to ensure threads are joined cleanly.

---

## Troubleshooting

**"Could not launch the Claude CLI" / panel shows install screen**

- Claude Code is not installed or not on your PATH.
- Use the Install button in the panel, or manually run: `npm install -g @anthropic-ai/claude-code`
- After installing, restart Godot so it picks up the updated PATH.

**"Claude returned no output"**

- You are likely not authenticated. Run `claude auth login` in a terminal and follow the prompts, then try again.

**Install fails with permission error (Linux/macOS)**

- Enable **"Use sudo"** in the install panel before clicking Install.
- Or install manually: `sudo npm install -g @anthropic-ai/claude-code`

**"Fix With Claude" or "Send To Claude" button is missing**

- These buttons are injected when the plugin loads. Try disabling and re-enabling the plugin in Project Settings → Plugins.
- Check the Output panel for any GDScript errors on plugin load.

**Responses appear all at once (no streaming)**

- Streaming is only available on Linux and macOS. On Windows, responses always appear when complete.

**Context is empty / Claude doesn't know about my scene**

- Make sure the **"Include context"** checkbox in the Context panel is enabled.
- Click **Preview** to see exactly what is being sent.
- Check that the context sections you want are enabled in Settings.

**Error log section shows nothing**

- The error log reads from Godot's file log. Enable file logging in:
  **Project Settings → Debug → File Logging → Enable File Logging**
- The log contains runtime errors (from Play mode), not editor errors.

**Plugin causes errors on load after editing**

- Godot caches `.gd` files. After editing plugin files, fully disable then re-enable the plugin in Project Settings → Plugins, or use **Project → Reload Current Project**.

**Godot Doctor section not visible in Settings**

- Godot Doctor must be installed (`addons/godot_doctor/`) and enabled before the Claude plugin loads. Enable Godot Doctor first, then disable and re-enable the Claude plugin.
