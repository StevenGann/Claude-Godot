@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/claude_godot/claude_panel.gd")
const ClaudeContextMenu = preload("res://addons/claude_godot/claude_context_menu.gd")

var _panel: Control
var _context_menu: EditorContextMenuPlugin


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	_panel.editor_plugin = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)

	get_editor_interface().get_selection().selection_changed.connect(
		_panel._on_selection_changed
	)

	_context_menu = ClaudeContextMenu.new()
	_context_menu.panel = _panel
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _context_menu)


func _exit_tree() -> void:
	if is_instance_valid(_context_menu):
		remove_context_menu_plugin(_context_menu)
		_context_menu = null

	if not is_instance_valid(_panel):
		return

	var selection = get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_panel._on_selection_changed):
		selection.selection_changed.disconnect(_panel._on_selection_changed)

	_panel.cleanup()
	remove_control_from_docks(_panel)
	_panel.queue_free()
	_panel = null
