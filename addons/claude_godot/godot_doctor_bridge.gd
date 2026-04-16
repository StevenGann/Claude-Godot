## Optional bridge to the Godot Doctor validation plugin.
## All public methods are safe to call even when Godot Doctor is not installed —
## they return gracefully without errors.
## Dynamic method/signal access is used throughout to avoid parse-time
## class references that would break projects without Godot Doctor installed.
@tool
class_name ClaudeGodotDoctorBridge
extends RefCounted

const _PLUGIN_SCRIPT_FILE: StringName = "godot_doctor_plugin.gd"
const _PLUGIN_SCRIPT_PATH: String = "res://addons/godot_doctor/godot_doctor_plugin.gd"

var _cached_dock: Control = null
var _fix_btn: Button = null


# ---------------------------------------------------------------------------
# Availability detection
# ---------------------------------------------------------------------------

## Returns true if Godot Doctor plugin files are present in this project.
func is_installed() -> bool:
	return ResourceLoader.exists(_PLUGIN_SCRIPT_PATH)


## Finds the active GodotDoctorPlugin EditorPlugin node by examining siblings
## of [param our_plugin] (both live as children of the editor's root node).
func get_plugin_node(our_plugin: EditorPlugin) -> Node:
	var parent := our_plugin.get_parent()
	if not parent:
		return null
	for sibling in parent.get_children():
		var script := sibling.get_script()
		if script is GDScript:
			if (script as GDScript).resource_path.get_file() == _PLUGIN_SCRIPT_FILE:
				return sibling
	return null


# ---------------------------------------------------------------------------
# Dock discovery
# ---------------------------------------------------------------------------

## Finds the GodotDoctorDock Control in the editor UI.
## The dock structure is: VBoxContainer("Godot Doctor") →
##   ValidateNowButton, ScrollContainer → ErrorHolder
## We locate it by finding "ErrorHolder" and navigating two levels up.
func find_dock(base: Control) -> Control:
	var error_holder := _find_node_by_name(base, "ErrorHolder")
	if not error_holder:
		return null
	var scroll_container := error_holder.get_parent()
	if not scroll_container:
		return null
	var dock := scroll_container.get_parent()
	if dock is Control:
		return dock as Control
	return null


func _find_node_by_name(root: Node, target_name: StringName) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found := _find_node_by_name(child, target_name)
		if found:
			return found
	return null


# ---------------------------------------------------------------------------
# "Fix with Claude" button injection
# ---------------------------------------------------------------------------

## Injects a "Fix with Claude" button into the Godot Doctor dock,
## placed directly after the "Validate Now" button.
## [param panel] must expose a [method fix_godot_doctor_issues](String) method.
## Returns true if injection succeeded.
func inject_fix_button(editor_plugin: EditorPlugin, panel: Control) -> bool:
	if not is_installed():
		return false
	var base := editor_plugin.get_editor_interface().get_base_control()
	var dock := find_dock(base)
	if not dock:
		return false
	_cached_dock = dock

	_fix_btn = Button.new()
	_fix_btn.text = "Fix with Claude"
	_fix_btn.tooltip_text = "Send current Godot Doctor issues to Claude for help fixing them"
	_fix_btn.pressed.connect(func(): _on_fix_pressed(panel))

	# Insert immediately after the "Validate Now" button.
	var insert_idx := dock.get_child_count()
	for i in range(dock.get_child_count()):
		var child := dock.get_child(i)
		if child is Button and (child as Button).text == "Validate Now":
			insert_idx = i + 1
			break
	dock.add_child(_fix_btn)
	dock.move_child(_fix_btn, insert_idx)
	return true


func _on_fix_pressed(panel: Control) -> void:
	if not is_instance_valid(_cached_dock):
		return
	var issues := _collect_issues_from_dock(_cached_dock)
	if issues.is_empty():
		issues = "(No issues currently listed in the Godot Doctor dock.)"
	if panel.has_method("fix_godot_doctor_issues"):
		panel.call("fix_godot_doctor_issues", issues)


# ---------------------------------------------------------------------------
# Validation trigger
# ---------------------------------------------------------------------------

## Triggers Godot Doctor validation of the current scene and inspected resource.
## Validation runs synchronously — when this returns, the dock reflects current results.
## Returns false if the GodotDoctorPlugin node could not be found.
func trigger_validation(our_plugin: EditorPlugin) -> bool:
	var plugin_node := get_plugin_node(our_plugin)
	if not plugin_node:
		push_warning("ClaudeGodot: GodotDoctorPlugin node not found — cannot trigger validation.")
		return false
	plugin_node.call("validate_scene_root_and_edited_resource")
	return true


# ---------------------------------------------------------------------------
# Issue collection
# ---------------------------------------------------------------------------

## Returns all current Godot Doctor issues as a formatted multi-line string.
## Uses the cached dock reference when available, otherwise searches the tree.
func collect_issues(editor_plugin: EditorPlugin) -> String:
	if not is_instance_valid(_cached_dock):
		var base := editor_plugin.get_editor_interface().get_base_control()
		_cached_dock = find_dock(base)
	if not is_instance_valid(_cached_dock):
		return ""
	return _collect_issues_from_dock(_cached_dock)


func _collect_issues_from_dock(dock: Control) -> String:
	var error_holder := dock.find_child("ErrorHolder", true, false)
	if not error_holder:
		return ""
	var lines: PackedStringArray
	for child in error_holder.get_children():
		var rich_label := _find_rich_text_label(child)
		if rich_label:
			var text := rich_label.get_parsed_text().strip_edges()
			if not text.is_empty():
				lines.append(text)
	return "\n".join(lines)


func _find_rich_text_label(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node as RichTextLabel
	for child in node.get_children():
		var found := _find_rich_text_label(child)
		if found:
			return found
	return null


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

func cleanup() -> void:
	if is_instance_valid(_fix_btn):
		_fix_btn.queue_free()
		_fix_btn = null
	_cached_dock = null
