# Claude Godot Plugin

A Godot 4 editor plugin that embeds [Claude Code](https://claude.ai/code) directly into the Godot editor UI.

## Features

- **Chat panel** docked in the Godot editor — ask Claude questions without leaving the editor
- **Editor context injection** — Claude automatically knows what scene and nodes you have open/selected
- **Error log access** — optionally include recent Godot errors and warnings with each message
- **File access mode** — let Claude read your project files to give more informed answers
- **Conversational sessions** — session continuity is maintained across messages and editor restarts
- **One-click install** — if Claude Code isn't installed, the panel offers to install it for you
- **Cross-platform** — works on Linux, Windows, and macOS

## Requirements

- Godot 4.x
- [Claude Code CLI](https://claude.ai/code) (`claude` in your PATH)
  - Requires [Node.js](https://nodejs.org) (for `npm install`)
  - An Anthropic account (free tier available)

## Installation

### 1. Add the plugin to your project

Copy the `addons/claude_godot/` folder into your Godot project's `addons/` directory.

### 2. Enable the plugin

In Godot: **Project → Project Settings → Plugins → Claude Godot → Enable**

### 3. Install Claude Code (if needed)

When the panel opens, if Claude Code is not installed it will offer to install it automatically. Click **"Install Claude Code"** and the panel will run:

```
npm install -g @anthropic-ai/claude-code
```

If you don't have npm, install [Node.js](https://nodejs.org) first.

### 4. Authenticate

After installation, click **"Authenticate"** to log in. This opens a terminal running `claude auth login`. Follow the prompts to connect your Anthropic account.

## Usage

The **Claude** panel appears in the top-right dock. Type a message and press **Ctrl+Enter** or click **Send**.

### Context Options

| Toggle | Default | Effect |
|--------|---------|--------|
| Include context | On | Sends current scene, selected nodes, and project info with each message |
| Errors | Off | Also includes recent errors/warnings from the Godot log file |
| File access | Off | Allows Claude to read files in your project directory |

### Context included automatically (when enabled)

- Current scene file path and root node
- Selected node(s): name, type, script, position, groups
- Project name, directory, and Godot version
- Recent runtime errors from `user://logs/godot.log` (optional)

### Session management

- **New** — starts a fresh conversation (clears session ID)
- **Clear** — clears the display but keeps the session going
- Sessions persist across editor restarts via editor metadata

## How it works

The plugin runs the `claude` CLI with `--print --output-format stream-json`. Editor context is injected via `--append-system-prompt`. Subprocess execution happens in a background thread so the Godot editor stays responsive.

### Cross-platform execution

| Platform | Command |
|----------|---------|
| Linux / macOS | `claude --print ...` |
| Windows | `cmd.exe /c claude --print ...` |

## Troubleshooting

**"Could not launch the Claude CLI"**
- Claude Code is not installed or not on your PATH
- Use the Install button in the panel, or run: `npm install -g @anthropic-ai/claude-code`
- Restart Godot after installing to refresh PATH

**"Claude returned no output"**
- You may not be authenticated — run `claude auth login` in a terminal

**Install fails with permission error (Linux/macOS)**
- Enable "Use sudo" in the install panel, or install manually with `sudo npm install -g @anthropic-ai/claude-code`

**"Errors" toggle shows nothing**
- Enable file logging in **Project Settings → Debug → File Logging → Enable File Logging**
- Errors are from game runtime (Play mode), not the Godot editor itself

## License

MIT
