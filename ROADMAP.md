# Claude Godot Plugin — Development Roadmap

Priority key: **Impact** (how much better the plugin gets) vs **Difficulty** (implementation effort).
Items are ordered within each phase by Impact/Difficulty ratio — highest ROI first.

---

## Phase 1 — Bug Fixes
*All bugs are low-difficulty. Do these before any features.*

| # | Issue | File | Difficulty | Impact |
|---|---|---|---|---|
| 1.1 | `_recent_errors()` returns non-empty string when there are no errors, causing "no errors" text to be injected as context | `context_builder.gd:224` | Trivial | High |
| 1.2 | RegEx objects recompiled on every response in `_markdown_to_bbcode()` | `claude_panel.gd:551` | Low | Medium |
| 1.3 | Script `resource_path` appended without checking for empty string (unsaved scripts) | `context_builder.gd:130` | Trivial | Low |
| 1.4 | Entire log file read into memory; could be MB for long-running projects | `context_builder.gd:208` | Low | Low |
| 1.5 | `_get_claude_exe_info()` is a redundant non-static wrapper around `_get_claude_exe_info_static()` | `claude_runner.gd:122` | Trivial | Low |
| 1.6 | Auth re-check timer can fire on freed panel; needs `is_instance_valid` guard | `claude_panel.gd:381` | Low | Medium |
| 1.7 | Stale session ID persists after new install flow; should be cleared in `_show_install_ui()` | `claude_panel.gd:227` | Trivial | Medium |

---

## Phase 2 — High-Impact, Low-Effort Context Additions
*All reachable via existing Godot editor APIs. Drop-in additions to `context_builder.gd`.*

### 2.1 — Open Scripts (all editor tabs, not just selected node)
- **API**: `EditorInterface.get_script_editor().get_open_scripts()` → returns `Array[Script]`
- **What to include**: path + first ~30 lines as "currently open scripts" section
- **Why**: Claude sees what the developer is actively working on across files
- **Difficulty**: Low | **Impact**: High

### 2.2 — Export Variables on Selected Node's Script
- **API**: Parse `script.source_code` for lines beginning with `@export`; or use `ClassDB` + `Script.get_script_property_list()`
- **What to include**: variable name, type hint, current value (from `node.get(prop_name)`)
- **Why**: Shows Claude the designer-facing interface of the node — critical for "add a feature to this node" requests
- **Difficulty**: Low-Medium | **Impact**: High

### 2.3 — Autoloads / Singletons
- **API**: Iterate `ProjectSettings`; autoloads are stored as `"autoload/SomeName"` keys
  ```gdscript
  for key in ProjectSettings.get_property_list():
      if key.name.begins_with("autoload/"):
          # key.name.trim_prefix("autoload/") = singleton name
          # ProjectSettings.get_setting(key.name) = path
  ```
- **Why**: Prevents Claude from inventing singleton names; knows `GameManager`, `AudioBus`, etc. exist
- **Difficulty**: Low | **Impact**: High

### 2.4 — Input Map Actions
- **API**: `InputMap.get_actions()` → filter out built-in `ui_*` actions
- **What to include**: action names only (not bindings, too verbose)
- **Why**: Prevents Claude from inventing `"jump"` when the project uses `"player_jump"`
- **Difficulty**: Trivial | **Impact**: Medium

### 2.5 — AnimationPlayer Clip Names on Selected Node
- **API**: Walk `node.get_children()` for `AnimationPlayer`; call `.get_animation_list()`
- **Why**: Prevents Claude from inventing animation names like `"walk"` when it's `"walk_cycle"`
- **Difficulty**: Trivial | **Impact**: Medium

### 2.6 — Node Signals and Connections
- **API**: `node.get_signal_list()`, `node.get_incoming_connections()`, `node.get_outgoing_connections()`
- **What to include**: custom signals (filter out engine built-ins) + active connections
- **Why**: Invaluable for debugging event-driven code and signal wiring questions
- **Difficulty**: Low | **Impact**: Medium

### 2.7 — Currently Open Scenes (all tabs)
- **API**: `EditorInterface.get_open_scenes()` → `Array[String]` of scene paths
- **Difficulty**: Trivial | **Impact**: Low-Medium

---

## Phase 3 — Settings & Fine-Tuning Controls
*Adds a Settings panel to the dock. Requires new UI section in `claude_panel.gd` and persistence via `EditorSettings`.*

### 3.1 — Custom System Prompt
- A `TextEdit` field the user fills in once: *"My project uses a custom event bus in EventBus.gd. All physics is 2D."*
- Prepended to every context injection
- Stored in `EditorSettings` project metadata
- **Difficulty**: Low | **Impact**: Very High (transforms Claude's relevance to the specific project)

### 3.2 — Context Section Toggles (granular)
Expand from 3 checkboxes to per-section controls:
- [ ] Include scene overview
- [ ] Include selected node detail
- [ ] Include open scripts list
- [ ] Include export variables
- [ ] Include autoloads
- [ ] Include input map
- [ ] Include recent errors (+ error count spinner: 5–50)
- [ ] Include full script source (selected node's script)
- All saved per-project in `EditorSettings`
- **Difficulty**: Low | **Impact**: High

### 3.3 — Context Preview
- "Preview context" button that opens an `AcceptDialog` showing exactly what system prompt will be sent
- Lets the user see and tune what Claude receives before hitting Send
- **Difficulty**: Low | **Impact**: Medium-High

### 3.4 — Model Selection
- Dropdown: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`
- Passed as `--model MODEL_ID` to the CLI
- Stored globally in `EditorSettings` (not per-project)
- **Difficulty**: Trivial | **Impact**: Medium (users can trade cost vs quality)

### 3.5 — Scene Tree Depth Control
- Spinner (1–5 levels deep) controlling how deep `_scene_context()` recurses
- Currently hardcoded to root's immediate children only
- **Difficulty**: Low | **Impact**: Medium

### 3.6 — Named Context Presets
- Save/load named configurations of all toggles: "Minimal", "Full Debug", "Code Review"
- Stored as JSON in `EditorSettings`
- **Difficulty**: Medium | **Impact**: Medium

---

## Phase 4 — Workflow Features
*Each improves how the user interacts with Claude during active development.*

### 4.1 — Prompt Templates / Quick Actions
- A dropdown (or button row) with pre-built prompts:
  - "Explain this node"
  - "Find bugs in this script"
  - "Optimize this for performance"
  - "Add a signal for [...]"
  - "Write a unit test for this"
  - "How do I connect this to [...]"
- Selecting one fills the input box (user can still edit before sending)
- Templates can reference context tokens: `{node_name}`, `{scene_name}`, `{script_path}`
- **Difficulty**: Low | **Impact**: High (biggest UX win for new users)

### 4.2 — Code Insertion Button on Code Blocks
- Add a small "Insert at cursor" button to each rendered code block bubble
- Uses `EditorInterface.get_script_editor().get_current_editor().get_base_editor()` to insert at cursor
- Falls back to clipboard copy if no script is open
- **Difficulty**: Medium | **Impact**: High (eliminates manual copy-paste workflow)

### 4.3 — Chat History Persistence
- Serialize chat messages (type + text) to `user://claude_godot/history.json` on each message
- Load on `_ready()` and restore bubbles (last N messages, configurable)
- Allows picking up a conversation after editor restart beyond just the session ID
- **Difficulty**: Medium | **Impact**: Medium-High

### 4.4 — "Fix This Error" Integration
- Add a thin toolbar button or keyboard shortcut that:
  1. Reads the last N lines from the Godot log (same path as `_recent_errors()`)
  2. Finds the most recent `SCRIPT ERROR` block (error message + stack trace)
  3. Loads the offending script path + surrounds the error line with context
  4. Pre-fills the Claude input: *"I'm getting this error: [error]. Here's the stack trace: [trace]. The code is: [lines around error]."*
- **Difficulty**: Medium | **Impact**: Very High (the single most common use case)

### 4.5 — "Ask Claude" Right-Click Menu in Scene Tree
- Hook into `EditorPlugin._get_window_layout()` or use `add_tool_menu_item()` 
- Add "Ask Claude about this node" to the scene tree context menu via `EditorPlugin`
- Pre-fills a prompt with the selected node's full context
- **Difficulty**: Medium-High | **Impact**: High

### 4.6 — Export Chat as Markdown
- "Export" button saves conversation to `res://claude_chat_YYYY-MM-DD.md`
- Useful for keeping AI-assisted design decisions in version control
- **Difficulty**: Low | **Impact**: Low-Medium

---

## Phase 5 — Advanced / High-Complexity Features
*Each requires significant design work. Implement after Phase 1–4 are stable.*

### 5.1 — Full Script Source Inclusion
- When selected, include the complete source of the selected node's attached `.gd` file
- Needs a size limit (skip if > 10,000 chars; show truncation warning)
- Toggle in Phase 3 settings
- **Difficulty**: Low | **Impact**: Very High (Claude can actually read the code)
- *Note: Simpler than it sounds — just `FileAccess.open(script.resource_path).get_as_text()`*

### 5.2 — Streaming Display
- Replace `OS.execute()` (blocking, output only at end) with:
  1. Write prompt + args to a temp file
  2. `OS.create_process()` with stdout redirected to `user://claude_stream.tmp`
  3. Poll `user://claude_stream.tmp` with a 100ms `Timer`
  4. Parse each new line as a stream-json event; render `assistant` content chunks incrementally
- Requires storing PID for timeout/kill, and cleanup of temp file
- **Difficulty**: High | **Impact**: High (dramatically better UX for long responses)

### 5.3 — Scene Screenshot as Context
- Capture the 2D or 3D viewport: `EditorInterface.get_editor_viewport_2d().get_texture()` → PNG bytes
- Encode as base64, pass via `--input-file` or stdin piping if the Claude CLI supports image input
- Falls back gracefully if Claude CLI version doesn't support images
- **Difficulty**: High | **Impact**: Medium-High ("why doesn't this look right?" queries)

### 5.4 — Multi-File Context Picker
- A popup file tree (using `EditorFileDialog` or a custom tree) to select specific `.gd` files
- Selected files are read and appended verbatim to the context
- Respects a total token budget (warn if too large)
- **Difficulty**: High | **Impact**: Medium-High

### 5.5 — Diff / Patch View for Code Changes
- When Claude's response contains a code block, attempt to diff it against the current file content
- Show a side-by-side diff in a popup using Godot's `CodeEdit`
- "Apply" button writes the patched file
- Requires identifying which file the code block belongs to (from context or user selection)
- **Difficulty**: Very High | **Impact**: High (if it works reliably)

---

## Priority Matrix Summary

```
HIGH IMPACT
    │
    │  1.1 bug   2.1 open scripts   4.4 fix error   5.1 script source
    │  2.3 autoload  3.1 custom prompt  4.1 templates   5.2 streaming
    │  2.2 exports   3.2 toggles     4.2 code insert
    │
    │  2.4 input map  3.3 preview    4.3 history     5.3 screenshot
    │  2.5 anim names  3.4 model     4.5 right-click  5.5 diff view
    │
    │  2.6 signals  3.5 depth ctrl  4.6 export chat  5.4 multi-file
    │
LOW IMPACT
    └─────────────────────────────────────────────────────────────────
    LOW DIFFICULTY                                       HIGH DIFFICULTY
```

## Suggested Sprint Order

| Sprint | Items | Goal |
|---|---|---|
| **Sprint 1** | All Phase 1 bugs | Stable, correct baseline |
| **Sprint 2** | 5.1, 2.1, 2.3, 2.4, 2.5, 2.6 | Rich context (the biggest Claude quality boost) |
| **Sprint 3** | 3.1, 3.2, 3.3, 3.4 | Settings panel — users can tune what Claude sees |
| **Sprint 4** | 4.1, 4.4, 4.2 | Workflow features with highest daily-use value |
| **Sprint 5** | 4.3, 4.5, 4.6, 2.7 | Polish and persistence |
| **Sprint 6** | 5.2, 5.3, 5.4, 5.5 | Ambitious features |
