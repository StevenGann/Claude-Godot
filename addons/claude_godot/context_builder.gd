## Gathers editor state and assembles a context string to inject into Claude prompts.
## All methods are static — no instance required.
##
## build() now accepts a settings Dictionary instead of simple flags.
## See claude_panel.gd _build_settings_dict() for the full key list.
@tool
class_name ContextBuilder
extends RefCounted

## How many bytes to read from the tail of the log file (avoids loading huge files).
const MAX_LOG_READ_BYTES := 65536
## Maximum characters for a script source inclusion before truncation.
const MAX_SCRIPT_SOURCE_CHARS := 8000


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

static func build(editor_plugin: EditorPlugin, settings: Dictionary) -> String:
	var parts: Array[String] = []

	# Custom project-specific prompt goes first so it frames everything below.
	var custom_prompt: String = settings.get("custom_prompt", "")
	if custom_prompt != "":
		parts.append(custom_prompt)

	parts.append(_preamble())

	if settings.get("include_scene", true):
		parts.append(_scene_context(editor_plugin, settings.get("scene_depth", 1)))

	if settings.get("include_selection", true):
		parts.append(_selection_context(editor_plugin, settings))

	if settings.get("include_open_scripts", true):
		parts.append(_open_scripts_context(editor_plugin))

	if settings.get("include_open_scenes", false):
		parts.append(_open_scenes_context(editor_plugin))

	if settings.get("include_autoloads", true):
		parts.append(_autoloads_context())

	if settings.get("include_input_map", false):
		parts.append(_input_map_context())

	if settings.get("include_logs", false):
		var logs := _recent_errors(settings.get("log_line_count", 20))
		if logs != "":
			parts.append("## Recent Godot Errors/Warnings\n" + logs)

	parts.append(_project_context())

	var filtered: Array[String] = []
	for p in parts:
		if p.strip_edges() != "":
			filtered.append(p)

	return "\n\n".join(filtered)


## Returns a short single-line summary for the panel's context status bar.
static func get_status_line(editor_plugin: EditorPlugin) -> String:
	if not is_instance_valid(editor_plugin):
		return "No editor"

	var ei := editor_plugin.get_editor_interface()
	var scene_root := ei.get_edited_scene_root()

	var scene_name := "No scene open"
	if is_instance_valid(scene_root):
		var path := scene_root.scene_file_path
		scene_name = path.get_file() if path != "" else scene_root.name + " (unsaved)"

	var selected := ei.get_selection().get_selected_nodes()
	var sel_text := "Nothing selected"
	if not selected.is_empty():
		if selected.size() == 1:
			var n := selected[0]
			sel_text = "%s (%s)" % [n.name, n.get_class()]
		else:
			sel_text = "%d nodes selected" % selected.size()

	return "Scene: %s   |   %s" % [scene_name, sel_text]


# ---------------------------------------------------------------------------
# Core context sections
# ---------------------------------------------------------------------------

static func _preamble() -> String:
	return (
		"You are a Godot 4 game development assistant running inside the Godot editor. " +
		"Help the user with GDScript coding, scene design, game mechanics, physics, UI, " +
		"animation, signals, and Godot 4 APIs. Prefer GDScript over C# unless asked. " +
		"When writing code, use Godot 4 syntax (not Godot 3). " +
		"The following sections describe the user's current editor state."
	)


static func _scene_context(editor_plugin: EditorPlugin, depth: int = 1) -> String:
	if not is_instance_valid(editor_plugin):
		return ""

	var ei := editor_plugin.get_editor_interface()
	var scene_root := ei.get_edited_scene_root()

	if not is_instance_valid(scene_root):
		return "## Current Scene\nNo scene is currently open."

	var path := scene_root.scene_file_path
	var lines: Array[String] = ["## Current Scene"]
	lines.append("File: " + (path if path != "" else "(unsaved)"))
	lines.append("Root node: %s (%s)" % [scene_root.name, scene_root.get_class()])
	lines.append("Direct children: %d" % scene_root.get_child_count())

	if scene_root.get_child_count() > 0:
		var tree_lines := _build_tree_recursive(scene_root, 0, depth - 1, 48)
		if not tree_lines.is_empty():
			lines.append("Scene tree:")
			lines.append_array(tree_lines)

	return "\n".join(lines)


static func _build_tree_recursive(
	node: Node,
	current_depth: int,
	max_depth: int,
	budget: int
) -> Array[String]:
	var lines: Array[String] = []
	var indent := "  ".repeat(current_depth + 1)
	for child in node.get_children():
		if lines.size() >= budget:
			lines.append(indent + "... (more children omitted)")
			break
		lines.append("%s- %s (%s)" % [indent, child.name, child.get_class()])
		if current_depth < max_depth and child.get_child_count() > 0:
			var sub := _build_tree_recursive(child, current_depth + 1, max_depth, budget - lines.size())
			lines.append_array(sub)
	return lines


static func _selection_context(editor_plugin: EditorPlugin, settings: Dictionary) -> String:
	if not is_instance_valid(editor_plugin):
		return ""

	var ei := editor_plugin.get_editor_interface()
	var selected := ei.get_selection().get_selected_nodes()

	if selected.is_empty():
		return "## Selected Nodes\nNothing is currently selected."

	var lines: Array[String] = ["## Selected Nodes"]
	for node in selected:
		lines.append(_describe_node(node))

	# Extended per-node context uses the first selected node only to keep output bounded.
	var first := selected[0]

	if settings.get("include_exports", true):
		var exports := _export_vars_context(first)
		if exports != "":
			lines.append("\n" + exports)

	if settings.get("include_animations", true):
		var anim := _animation_context(first)
		if anim != "":
			lines.append("\n" + anim)

	if settings.get("include_signals", false):
		var sigs := _signals_context(first)
		if sigs != "":
			lines.append("\n" + sigs)

	if settings.get("include_script_source", false):
		var src := _full_script_source(first)
		if src != "":
			lines.append("\n" + src)

	return "\n".join(lines)


static func _describe_node(node: Node) -> String:
	var lines: Array[String] = []
	lines.append("- %s (%s)" % [node.name, node.get_class()])

	if node.scene_file_path != "":
		lines.append("  Scene: " + node.scene_file_path)

	var script = node.get_script()
	if script != null:
		# Bug fix 1.3: guard against empty resource_path (unsaved/built-in scripts)
		if script.resource_path != "":
			lines.append("  Script: " + script.resource_path)

	var scene_root := node.get_tree().edited_scene_root if node.get_tree() else null
	if is_instance_valid(scene_root):
		lines.append("  Path: " + str(scene_root.get_path_to(node)))

	if "position" in node:
		lines.append("  Position: " + str(node.get("position")))
	if "rotation_degrees" in node:
		lines.append("  Rotation: " + str(node.get("rotation_degrees")))
	if "scale" in node:
		lines.append("  Scale: " + str(node.get("scale")))
	if "visible" in node:
		lines.append("  Visible: " + str(node.get("visible")))

	if node.get_class() in [
		"CharacterBody2D", "CharacterBody3D",
		"RigidBody2D", "RigidBody3D",
		"StaticBody2D", "StaticBody3D",
		"Area2D", "Area3D"
	]:
		if "collision_layer" in node:
			lines.append("  Collision layer: %d" % int(node.get("collision_layer")))
		if "collision_mask" in node:
			lines.append("  Collision mask: %d" % int(node.get("collision_mask")))

	if node.get_class() in ["Camera2D", "Camera3D"]:
		if "current" in node:
			lines.append("  Current: " + str(node.get("current")))

	var groups := node.get_groups()
	if not groups.is_empty():
		lines.append("  Groups: " + ", ".join(groups))

	return "\n".join(lines)


static func _project_context() -> String:
	var project_name: String = ProjectSettings.get_setting(
		"application/config/name", "Unnamed Project"
	)
	var project_dir := ProjectSettings.globalize_path("res://")
	var vi := Engine.get_version_info()
	var version_str := "%d.%d.%d" % [
		vi.get("major", 4), vi.get("minor", 0), vi.get("patch", 0)
	]
	return (
		"## Project\n" +
		"Name: %s\n" % project_name +
		"Directory: %s\n" % project_dir +
		"Godot version: %s" % version_str
	)


# ---------------------------------------------------------------------------
# Sprint 2 — new context sections
# ---------------------------------------------------------------------------

## 2.1 — Open scripts (all editor script tabs, not just selected node's script)
static func _open_scripts_context(editor_plugin: EditorPlugin) -> String:
	if not is_instance_valid(editor_plugin):
		return ""
	var se := editor_plugin.get_editor_interface().get_script_editor()
	var scripts := se.get_open_scripts()
	if scripts.is_empty():
		return ""
	var lines: Array[String] = ["## Open Scripts"]
	for script in scripts:
		if script != null and script.resource_path != "":
			lines.append("  " + script.resource_path)
	return "" if lines.size() <= 1 else "\n".join(lines)


## 2.2 — Export variables on the selected node's script
static func _export_vars_context(node: Node) -> String:
	var script = node.get_script()
	if script == null or script.resource_path == "":
		return ""

	# Parse @export declarations from source; get live values from the node.
	var found: Array[String] = []
	var var_re := RegEx.new()
	var_re.compile("\\bvar\\s+(\\w+)")

	for line in script.source_code.split("\n"):
		var stripped: String = line.strip_edges()
		if not stripped.begins_with("@export"):
			continue
		var m := var_re.search(stripped)
		if m == null:
			continue
		var var_name := m.get_string(1)
		var value = node.get(var_name)
		var value_str := str(value) if value != null else "(null)"
		found.append("  %s = %s" % [var_name, value_str])

	if found.is_empty():
		return ""
	var lines: Array[String] = ["## Export Variables (%s)" % node.name]
	lines.append_array(found)
	return "\n".join(lines)


## 2.3 — Autoloads / singletons
static func _autoloads_context() -> String:
	var entries: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		var key: String = prop.get("name", "")
		if not key.begins_with("autoload/"):
			continue
		var singleton_name := key.trim_prefix("autoload/")
		var path: String = str(ProjectSettings.get_setting(key, ""))
		path = path.trim_prefix("*")  # Godot prefixes enabled autoloads with *
		entries.append("  %s → %s" % [singleton_name, path])
	if entries.is_empty():
		return ""
	var lines: Array[String] = ["## Autoloads (Singletons)"]
	lines.append_array(entries)
	return "\n".join(lines)


## 2.4 — Input map custom actions (excludes built-in ui_* actions)
static func _input_map_context() -> String:
	var actions: Array[String] = []
	for action in InputMap.get_actions():
		if not (action as String).begins_with("ui_"):
			actions.append("  " + action)
	if actions.is_empty():
		return ""
	var lines: Array[String] = ["## Input Actions"]
	lines.append_array(actions)
	return "\n".join(lines)


## 2.5 — AnimationPlayer clip names on the selected node and its children
static func _animation_context(node: Node) -> String:
	var results: Array[String] = []
	var queue: Array[Node] = [node]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is AnimationPlayer:
			var clips := (n as AnimationPlayer).get_animation_list()
			if not clips.is_empty():
				results.append("  AnimationPlayer '%s': %s" % [n.name, ", ".join(clips)])
		queue.append_array(n.get_children())
	if results.is_empty():
		return ""
	var lines: Array[String] = ["## Animations (%s)" % node.name]
	lines.append_array(results)
	return "\n".join(lines)


## 2.6 — User-defined signals and active connections on the selected node
static func _signals_context(node: Node) -> String:
	var lines: Array[String] = []

	# Parse script source for signal declarations
	var script = node.get_script()
	if script != null and script.resource_path != "":
		var defined: Array[String] = []
		for line in script.source_code.split("\n"):
			var s: String = line.strip_edges()
			if s.begins_with("signal "):
				defined.append("  " + s)
		if not defined.is_empty():
			lines.append("  Defined:")
			lines.append_array(defined)

	# Active outgoing connections on all signals
	var conn_lines: Array[String] = []
	for sig_dict in node.get_signal_list():
		var sig_name: String = sig_dict["name"]
		var conns := node.get_signal_connection_list(sig_name)
		for conn in conns:
			var callable: Callable = conn["callable"]
			var target = callable.get_object()
			if target == null:
				continue
			var target_name: String = target.name if target is Node else str(target)
			conn_lines.append("  %s → %s.%s()" % [sig_name, target_name, callable.get_method()])
	if not conn_lines.is_empty():
		lines.append("  Active connections:")
		lines.append_array(conn_lines)

	if lines.is_empty():
		return ""
	var header := ["## Signals (%s)" % node.name]
	header.append_array(lines)
	return "\n".join(header)


## 2.7 — Currently open scene files (all editor tabs)
static func _open_scenes_context(editor_plugin: EditorPlugin) -> String:
	if not is_instance_valid(editor_plugin):
		return ""
	var scenes := editor_plugin.get_editor_interface().get_open_scenes()
	if scenes.is_empty():
		return ""
	var lines: Array[String] = ["## Open Scenes"]
	for path in scenes:
		lines.append("  " + path)
	return "\n".join(lines)


## 5.1 — Full source of the selected node's script (capped at MAX_SCRIPT_SOURCE_CHARS)
static func _full_script_source(node: Node) -> String:
	var script = node.get_script()
	if script == null or script.resource_path == "":
		return ""
	var file := FileAccess.open(script.resource_path, FileAccess.READ)
	if file == null:
		return ""
	var source := file.get_as_text()
	file.close()
	var note := ""
	if source.length() > MAX_SCRIPT_SOURCE_CHARS:
		source = source.left(MAX_SCRIPT_SOURCE_CHARS)
		note = "\n... [truncated at %d characters]" % MAX_SCRIPT_SOURCE_CHARS
	return "## Script Source: %s\n```gdscript\n%s%s\n```" % [script.resource_path, source, note]


# ---------------------------------------------------------------------------
# Log file access (Sprint 1 bug fixes 1.1 + 1.4)
# ---------------------------------------------------------------------------

## Reads the tail of the Godot log and returns the last N error/warning lines.
## Returns "" (not a "no errors" message) when nothing is found, so callers
## can use a simple `if logs != "":` guard without injecting noise.
static func _recent_errors(line_count: int = 20) -> String:
	var base := OS.get_user_data_dir() + "/logs/"
	var log_path := ""
	for candidate in ["godot.log", "godot_1.log", "godot_2.log"]:
		if FileAccess.file_exists(base + candidate):
			log_path = base + candidate
			break

	if log_path == "":
		return ""

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return ""

	# Bug fix 1.4: Seek near the end of the file to avoid reading megabytes.
	var file_len := file.get_length()
	if file_len > MAX_LOG_READ_BYTES:
		file.seek(file_len - MAX_LOG_READ_BYTES)

	var content := file.get_as_text()
	file.close()

	var relevant: Array[String] = []
	for line in content.split("\n"):
		var upper := line.to_upper()
		if "ERROR" in upper or "WARNING" in upper or "SCRIPT ERROR" in upper:
			var stripped := line.strip_edges()
			if stripped != "":
				relevant.append(stripped)

	# Bug fix 1.1: return "" when no errors, not a descriptive message.
	if relevant.is_empty():
		return ""

	var start := max(0, relevant.size() - line_count)
	return "\n".join(relevant.slice(start))
