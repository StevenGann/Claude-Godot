@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/claude_godot/claude_panel.gd")

var _panel: Control


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	_panel.editor_plugin = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)

	get_editor_interface().get_selection().selection_changed.connect(
		_panel._on_selection_changed
	)


func _exit_tree() -> void:
	if not is_instance_valid(_panel):
		return

	var selection = get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_panel._on_selection_changed):
		selection.selection_changed.disconnect(_panel._on_selection_changed)

	_panel.cleanup()
	remove_control_from_docks(_panel)
	_panel.queue_free()
	_panel = null
