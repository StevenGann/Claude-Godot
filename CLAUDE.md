# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Godot 4 editor plugin (`addons/claude_godot/`) that embeds the Claude Code CLI into the Godot editor as a docked chat panel. There is no build system — all code is GDScript run directly by Godot. Changes are tested by enabling/reloading the plugin inside a Godot 4 project.

## Testing Changes

There is no automated test suite. To test:

1. Copy (or symlink) `addons/claude_godot/` into a Godot 4 project's `addons/` folder.
2. In Godot: **Project → Project Settings → Plugins → Claude Godot → Enable**.
3. Watch the **Output** panel for compilation errors — GDScript errors appear there immediately on plugin load.
4. To reload after edits: disable and re-enable the plugin, or use **Project → Reload Current Project**.

Common pitfall: Godot caches `.gd` files. After editing, fully disabling then re-enabling the plugin ensures the new code is loaded.

## Architecture

All files are `@tool` scripts (run in the editor, not at game runtime).

| File | Role |
|---|---|
| `plugin.gd` | `EditorPlugin` entry point — creates the panel, registers context menu |
| `claude_panel.gd` | Main docked `Control` — all UI built programmatically, handles state, session persistence, chat history |
| `claude_runner.gd` (`ClaudeRunner`) | Executes `claude` CLI in a background `Thread`; communicates back to panel via signals using `call_deferred()` |
| `context_builder.gd` (`ContextBuilder`) | Static methods only — reads editor state and assembles the `--append-system-prompt` string |
| `claude_context_menu.gd` | `EditorContextMenuPlugin` — adds "Ask Claude about this" to scene tree right-click |

### Key design constraints

- **Thread safety**: `ClaudeRunner` runs `OS.execute()` on a background thread. Any UI update must go through `call_deferred()`. Never touch `Control` nodes from the thread.
- **No `.tscn` files**: The entire UI is built in code inside `claude_panel.gd::_build_ui()`. Avoids `.tscn` load-order issues with `@tool` scripts.
- **`preload` for class resolution**: `claude_panel.gd` uses `const ClaudeRunner = preload(...)` and `const ContextBuilder = preload(...)` so that `class_name` declarations in those files are available at parse time.
- **`ContextBuilder` is stateless**: All methods are `static`. Pass `editor_plugin` and a settings `Dictionary` into `build()`; it returns a plain `String`.

### Claude CLI invocation

`ClaudeRunner.send()` builds args like:
```
claude --print --output-format stream-json --verbose
      [--model MODEL_ID]
      [--append-system-prompt CONTEXT]
      [--add-dir PROJECT_DIR --dangerously-skip-permissions]
      [--resume SESSION_ID]
      USER_MESSAGE
```

On Windows, `claude` is wrapped as `cmd.exe /c claude ...`.

Output is newline-delimited JSON; `_parse_stream_json()` scans for the `{"type":"result"}` event to extract the final response text and `session_id`.

### Session & settings persistence

- Session ID and settings are stored in Godot's `EditorSettings` project metadata under the key `"claude_godot_plugin"` via `ProjectSettings` or the editor's `get_meta()`/`set_meta()` methods.
- Chat history (last 100 messages) is serialized to `user://claude_godot/history.json`.

## GDScript Notes

- Target: Godot 4.x GDScript (not Godot 3). Use `super()` not `.()`, `@export` not `export`, etc.
- All plugin scripts must have `@tool` at the top.
- `is_instance_valid(node)` before accessing any potentially-freed node reference.
- Prefer `push_warning()` / `push_error()` for non-fatal issues rather than `print()`.
