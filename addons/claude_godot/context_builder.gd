## Gathers editor state and assembles a context string to inject into Claude prompts.
## All methods are static — no instance required.
@tool
class_name ContextBuilder
extends RefCounted


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

static func build(editor_plugin: EditorPlugin, include_logs: bool) -> String:
	var parts: Array[String] = []

	parts.append(_preamble())
	parts.append(_scene_context(editor_plugin))
	parts.append(_selection_context(editor_plugin))
	parts.append(_project_context())

	if include_logs:
		var logs := _recent_errors()
		if logs != "":
			parts.append("## Recent Godot Errors/Warnings\n" + logs)

	# Remove empty parts before joining
	var filtered: Array[String] = []
	for p in parts:
		if p.strip_edges() != "":
			filtered.append(p)

	return "\n\n".join(filtered)


static func get_status_line(editor_plugin: EditorPlugin) -> String:
	## Returns a short single-line summary for the panel's context status bar.
	if not is_instance_valid(editor_plugin):
		return "No editor"

	var ei := editor_plugin.get_editor_interface()
	var scene_root := ei.get_edited_scene_root()

	var scene_name := "No scene open"
	if is_instance_valid(scene_root):
		var path := scene_root.scene_file_path
		if path != "":
			scene_name = path.get_file()
		else:
			scene_name = scene_root.name + " (unsaved)"

	var selected := ei.get_selection().get_selected_nodes()
	var sel_text := "Nothing selected"
	if not selected.is_empty():
		if selected.size() == 1:
			var n := selected[0]
			sel_text = n.name + " (" + n.get_class() + ")"
		else:
			sel_text = str(selected.size()) + " nodes selected"

	return "Scene: %s   |   %s" % [scene_name, sel_text]


# ---------------------------------------------------------------------------
# Context sections
# ---------------------------------------------------------------------------

static func _preamble() -> String:
	return (
		"You are a Godot 4 game development assistant running inside the Godot editor. " +
		"Help the user with GDScript coding, scene design, game mechanics, physics, UI, " +
		"animation, signals, and Godot 4 APIs. Prefer GDScript over C# unless asked. " +
		"When writing code, use Godot 4 syntax (not Godot 3). " +
		"The following sections describe the user's current editor state."
	)


static func _scene_context(editor_plugin: EditorPlugin) -> String:
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

	# List immediate children for scene overview
	if scene_root.get_child_count() > 0 and scene_root.get_child_count() <= 12:
		var child_list: Array[String] = []
		for child in scene_root.get_children():
			child_list.append("  - %s (%s)" % [child.name, child.get_class()])
		lines.append("Children:\n" + "\n".join(child_list))

	return "\n".join(lines)


static func _selection_context(editor_plugin: EditorPlugin) -> String:
	if not is_instance_valid(editor_plugin):
		return ""

	var ei := editor_plugin.get_editor_interface()
	var selected := ei.get_selection().get_selected_nodes()

	if selected.is_empty():
		return "## Selected Nodes\nNothing is currently selected."

	var lines: Array[String] = ["## Selected Nodes"]
	for node in selected:
		lines.append(_describe_node(node))

	return "\n".join(lines)


static func _describe_node(node: Node) -> String:
	var lines: Array[String] = []
	lines.append("- %s (%s)" % [node.name, node.get_class()])

	# Scene-file path (if this node is a scene instance)
	if node.scene_file_path != "":
		lines.append("  Scene: " + node.scene_file_path)

	# Attached script
	var script = node.get_script()
	if script != null:
		lines.append("  Script: " + script.resource_path)

	# Node path from scene root
	var scene_root := node.get_tree().edited_scene_root if node.get_tree() else null
	if is_instance_valid(scene_root):
		lines.append("  Path: " + str(scene_root.get_path_to(node)))

	# Spatial transform (2D or 3D)
	if "position" in node:
		lines.append("  Position: " + str(node.get("position")))
	if "rotation_degrees" in node:
		lines.append("  Rotation: " + str(node.get("rotation_degrees")))
	if "scale" in node:
		lines.append("  Scale: " + str(node.get("scale")))
	if "visible" in node:
		lines.append("  Visible: " + str(node.get("visible")))

	# Physics bodies
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

	# Camera
	if node.get_class() in ["Camera2D", "Camera3D"]:
		if "current" in node:
			lines.append("  Current: " + str(node.get("current")))

	# Groups
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
		vi.get("major", 4),
		vi.get("minor", 0),
		vi.get("patch", 0)
	]

	return (
		"## Project\n" +
		"Name: %s\n" % project_name +
		"Directory: %s\n" % project_dir +
		"Godot version: %s" % version_str
	)


static func _recent_errors() -> String:
	## Reads the Godot user log file and returns the last 20 error/warning lines.
	## OS.get_user_data_dir() returns the correct platform-specific path automatically.
	var base := OS.get_user_data_dir() + "/logs/"
	var candidates := ["godot.log", "godot_1.log", "godot_2.log"]

	var log_path := ""
	for name in candidates:
		if FileAccess.file_exists(base + name):
			log_path = base + name
			break

	if log_path == "":
		return ""

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return ""

	var content := file.get_as_text()
	file.close()

	var relevant: Array[String] = []
	for line in content.split("\n"):
		var upper := line.to_upper()
		if "ERROR" in upper or "WARNING" in upper or "SCRIPT ERROR" in upper:
			var stripped := line.strip_edges()
			if stripped != "":
				relevant.append(stripped)

	if relevant.is_empty():
		return "(No recent errors or warnings found in log)"

	var start := max(0, relevant.size() - 20)
	return "\n".join(relevant.slice(start))
