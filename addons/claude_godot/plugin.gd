@tool
extends EditorPlugin

const ClaudePanel = preload("res://addons/claude_godot/claude_panel.gd")
const ClaudeContextMenu = preload("res://addons/claude_godot/claude_context_menu.gd")
const ClaudeGodotDoctorBridge = preload("res://addons/claude_godot/godot_doctor_bridge.gd")

var _panel: Control
var _context_menu: EditorContextMenuPlugin
var _fix_errors_btn: Button = null
var _errors_tree_ref: Tree = null  # reference to the error Tree widget in the Errors tab
var _send_output_btn: Button = null
var _output_log_ref: RichTextLabel = null  # reference to the Output tab's log label
var _gd_bridge: ClaudeGodotDoctorBridge = null


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

	_gd_bridge = ClaudeGodotDoctorBridge.new()
	_panel.response_finished.connect(_on_panel_response_finished)

	# Defer UI injections until after all plugins have entered the tree.
	call_deferred("_inject_fix_errors_button")
	call_deferred("_inject_send_output_button")
	call_deferred("_inject_godot_doctor_button")


func _exit_tree() -> void:
	_errors_tree_ref = null
	if is_instance_valid(_fix_errors_btn):
		_fix_errors_btn.queue_free()
		_fix_errors_btn = null

	_output_log_ref = null
	if is_instance_valid(_send_output_btn):
		_send_output_btn.queue_free()
		_send_output_btn = null

	if _gd_bridge != null:
		_gd_bridge.cleanup()
		_gd_bridge = null

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


# ---------------------------------------------------------------------------
# Debugger Errors tab — "Fix With Claude" button injection
# ---------------------------------------------------------------------------

func _inject_fix_errors_button() -> void:
	var base := get_editor_interface().get_base_control()
	var section := _find_errors_section(base)
	if not is_instance_valid(section.get("toolbar")):
		push_warning("ClaudeGodot: Could not locate Debugger Errors tab toolbar — 'Fix With Claude' button not added.")
		return

	_errors_tree_ref = section.get("error_tree")

	_fix_errors_btn = Button.new()
	_fix_errors_btn.text = "Fix With Claude"
	_fix_errors_btn.tooltip_text = "Send current errors to Claude for help fixing them"
	_fix_errors_btn.pressed.connect(_on_fix_errors_pressed)

	var toolbar: HBoxContainer = section["toolbar"]
	# Insert the button immediately after the "Clear" button.
	var insert_idx := toolbar.get_child_count()
	for i in range(toolbar.get_child_count()):
		var child := toolbar.get_child(i)
		if child is Button and child.text == "Clear":
			insert_idx = i + 1
			break
	toolbar.add_child(_fix_errors_btn)
	toolbar.move_child(_fix_errors_btn, insert_idx)


## Recursively searches for the "Errors" tab inside any TabContainer and
## returns {toolbar: HBoxContainer, error_tree: Tree} or empty dict on failure.
func _find_errors_section(node: Node) -> Dictionary:
	if node is TabContainer:
		for i in range(node.get_tab_count()):
			if node.get_tab_title(i) == "Errors":
				var tab_content := node.get_child(i)
				return {
					"toolbar": _find_hbox_with_clear(tab_content),
					"error_tree": _find_first_tree(tab_content),
				}
	for child in node.get_children():
		var result := _find_errors_section(child)
		if result.has("toolbar"):
			return result
	return {}


func _find_hbox_with_clear(node: Node) -> HBoxContainer:
	if node is HBoxContainer:
		for child in node.get_children():
			if child is Button and child.text == "Clear":
				return node
	for child in node.get_children():
		var found := _find_hbox_with_clear(child)
		if found:
			return found
	return null


func _find_first_tree(node: Node) -> Tree:
	if node is Tree:
		return node
	for child in node.get_children():
		var found := _find_first_tree(child)
		if found:
			return found
	return null


func _on_fix_errors_pressed() -> void:
	if not is_instance_valid(_panel):
		return
	var errors_text := _collect_errors_from_tree()
	if errors_text.is_empty():
		errors_text = "(No errors currently listed in the Errors tab. Please describe your issue.)"
	_panel.fix_errors(errors_text)


# ---------------------------------------------------------------------------
# Output tab — "Send To Claude" button injection
# ---------------------------------------------------------------------------

func _inject_send_output_button() -> void:
	var base := get_editor_interface().get_base_control()
	var section := _find_output_section(base)
	if not is_instance_valid(section.get("toolbar")):
		push_warning("ClaudeGodot: Could not locate Output tab toolbar — 'Send To Claude' button not added.")
		return

	_output_log_ref = section.get("log_label")

	_send_output_btn = Button.new()
	_send_output_btn.text = "Send To Claude"
	_send_output_btn.tooltip_text = "Send the current output log to Claude for review"
	_send_output_btn.pressed.connect(_on_send_output_pressed)

	var toolbar: HBoxContainer = section["toolbar"]
	# Insert immediately after the "Clear" button.
	var insert_idx := toolbar.get_child_count()
	for i in range(toolbar.get_child_count()):
		var child := toolbar.get_child(i)
		if child is Button and child.text == "Clear":
			insert_idx = i + 1
			break
	toolbar.add_child(_send_output_btn)
	toolbar.move_child(_send_output_btn, insert_idx)


## Finds the Output tab inside any TabContainer and returns
## {toolbar: HBoxContainer, log_label: RichTextLabel} or empty dict on failure.
func _find_output_section(node: Node) -> Dictionary:
	if node is TabContainer:
		for i in range(node.get_tab_count()):
			if node.get_tab_title(i) == "Output":
				var tab_content := node.get_child(i)
				return {
					"toolbar": _find_hbox_with_clear(tab_content),
					"log_label": _find_first_rich_text_label(tab_content),
				}
	for child in node.get_children():
		var result := _find_output_section(child)
		if result.has("toolbar"):
			return result
	return {}


func _find_first_rich_text_label(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node
	for child in node.get_children():
		var found := _find_first_rich_text_label(child)
		if found:
			return found
	return null


func _on_send_output_pressed() -> void:
	if not is_instance_valid(_panel):
		return
	var log_text := ""
	if is_instance_valid(_output_log_ref):
		log_text = _output_log_ref.get_parsed_text().strip_edges()
	if log_text.is_empty():
		log_text = "(The output log is empty.)"
	_panel.send_output_log(log_text)


# ---------------------------------------------------------------------------
# Godot Doctor integration
# ---------------------------------------------------------------------------

func _inject_godot_doctor_button() -> void:
	if not _gd_bridge.is_installed():
		return
	var ok := _gd_bridge.inject_fix_button(self, _panel)
	if not ok:
		push_warning("ClaudeGodot: Could not inject 'Fix with Claude' button into the Godot Doctor dock.")


func _on_panel_response_finished() -> void:
	if not _read_setting("godot_doctor_auto_validate", false):
		return
	if not _gd_bridge.is_installed():
		return
	var validated := _gd_bridge.trigger_validation(self)
	if not validated:
		return
	if not _read_setting("godot_doctor_auto_send", false):
		return
	var issues := _gd_bridge.collect_issues(self)
	if issues.is_empty():
		return
	if is_instance_valid(_panel):
		_panel.call("fix_godot_doctor_issues", issues)


## Reads a Claude Godot plugin setting from EditorSettings project metadata.
func _read_setting(key: String, default_val: Variant) -> Variant:
	return get_editor_interface().get_editor_settings() \
		.get_project_metadata("claude_godot_plugin", key, default_val)


func _collect_errors_from_tree() -> String:
	if not is_instance_valid(_errors_tree_ref):
		return ""
	var root := _errors_tree_ref.get_root()
	if not root:
		return ""
	var lines: PackedStringArray
	var item := root.get_first_child()
	while item:
		var parts: PackedStringArray
		for col in range(_errors_tree_ref.get_columns()):
			var text := item.get_text(col).strip_edges()
			if not text.is_empty():
				parts.append(text)
		if parts.size() > 0:
			lines.append(" | ".join(parts))
		item = item.get_next()
	return "\n".join(lines)
