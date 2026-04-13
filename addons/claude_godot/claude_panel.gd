## Main docked panel for the Claude Godot plugin.
## Builds its entire UI programmatically (no .tscn dependency).
@tool
extends Control

# Explicit preloads ensure dependency scripts are compiled before this file,
# resolving class_name references that may not yet be registered at load time.
const ClaudeRunner = preload("res://addons/claude_godot/claude_runner.gd")
const ContextBuilder = preload("res://addons/claude_godot/context_builder.gd")

## Set by plugin.gd before this control is added to the dock.
var editor_plugin: EditorPlugin

# ---------------------------------------------------------------------------
# UI node references (populated in _build_ui)
# ---------------------------------------------------------------------------
var _root_vbox: VBoxContainer
var _scroll_container: ScrollContainer
var _chat_vbox: VBoxContainer
var _input_text: TextEdit
var _send_button: Button
var _new_chat_button: Button
var _status_label: Label
var _context_info_label: RichTextLabel
var _context_body: VBoxContainer
var _include_context_toggle: CheckButton
var _file_access_toggle: CheckButton
var _settings_body: VBoxContainer
var _model_option: OptionButton
var _custom_prompt_edit: TextEdit
var _scene_depth_spin: SpinBox
var _log_lines_spin: SpinBox
## Maps context section setting key -> CheckBox node, iterated in _build_settings_dict().
var _ctx_toggles: Dictionary = {}

# Install overlay nodes
var _install_overlay: PanelContainer
var _install_status_label: RichTextLabel
var _install_button: Button
var _auth_button: Button
var _sudo_check: CheckButton

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _runner: ClaudeRunner
var _session_id: String = ""
var _install_check_thread: Thread = null
const _SETTINGS_KEY := "claude_godot_plugin"

# Bug fix 1.2: Pre-compiled RegEx — allocated once in _ready(), not on every message.
var _re_code_block: RegEx
var _re_inline_code: RegEx
var _re_bold: RegEx
var _re_italic: RegEx

# Model list: [display name, model ID]
const _MODELS: Array = [
	["Sonnet 4.6 (Default)", "claude-sonnet-4-6"],
	["Opus 4.6 (Most Capable)", "claude-opus-4-6"],
	["Haiku 4.5 (Fastest)", "claude-haiku-4-5"],
]


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	name = "Claude"
	custom_minimum_size = Vector2(240, 400)

	_compile_regexes()

	_runner = ClaudeRunner.new()
	_runner.response_received.connect(_on_response_received)
	_runner.error_occurred.connect(_on_error_occurred)
	_runner.request_started.connect(_on_request_started)
	_runner.install_progress.connect(_on_install_progress)
	_runner.install_finished.connect(_on_install_finished)

	_build_ui()
	_load_session_state()
	_check_claude_installed_async()


func cleanup() -> void:
	## Called by plugin.gd before queue_free() to safely join threads.
	if _runner:
		_runner.cleanup()
	if _install_check_thread != null and _install_check_thread.is_started():
		_install_check_thread.wait_to_finish()


func _on_selection_changed() -> void:
	_update_context_display()


# ---------------------------------------------------------------------------
# UI Construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_root_vbox = VBoxContainer.new()
	_root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_vbox.add_theme_constant_override("separation", 4)
	add_child(_root_vbox)

	_build_title_bar()
	_root_vbox.add_child(HSeparator.new())
	_build_context_section()
	_root_vbox.add_child(HSeparator.new())
	_build_settings_section()
	_root_vbox.add_child(HSeparator.new())
	_build_chat_area()
	_root_vbox.add_child(HSeparator.new())
	_build_status_bar()
	_build_input_area()


func _build_title_bar() -> void:
	var hbox := HBoxContainer.new()
	_root_vbox.add_child(hbox)

	var title := Label.new()
	title.text = "Claude Assistant"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 14)
	hbox.add_child(title)

	_new_chat_button = Button.new()
	_new_chat_button.text = "New"
	_new_chat_button.tooltip_text = "Start a new conversation (clears session)"
	_new_chat_button.pressed.connect(_on_new_chat_pressed)
	hbox.add_child(_new_chat_button)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.tooltip_text = "Clear the chat display (session continues)"
	clear_btn.pressed.connect(_on_clear_pressed)
	hbox.add_child(clear_btn)


func _build_context_section() -> void:
	var toggle_btn := Button.new()
	toggle_btn.text = "Context ▼"
	toggle_btn.flat = true
	toggle_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(toggle_btn)

	_context_body = VBoxContainer.new()
	_context_body.add_theme_constant_override("separation", 3)
	_root_vbox.add_child(_context_body)

	toggle_btn.pressed.connect(func():
		_context_body.visible = not _context_body.visible
		toggle_btn.text = "Context ▼" if _context_body.visible else "Context ▶"
	)

	# Scene/selection status line
	_context_info_label = RichTextLabel.new()
	_context_info_label.bbcode_enabled = false
	_context_info_label.fit_content = true
	_context_info_label.scroll_active = false
	_context_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_context_info_label.custom_minimum_size.y = 32
	_context_body.add_child(_context_info_label)

	# Quick toggles + context preview button
	var row := HBoxContainer.new()
	_context_body.add_child(row)

	_include_context_toggle = CheckButton.new()
	_include_context_toggle.text = "Include context"
	_include_context_toggle.button_pressed = _get_setting("include_context_master", true)
	_include_context_toggle.tooltip_text = "Inject editor state with each message (configure sections in Settings)"
	_include_context_toggle.toggled.connect(func(on: bool): _save_setting("include_context_master", on))
	row.add_child(_include_context_toggle)

	_file_access_toggle = CheckButton.new()
	_file_access_toggle.text = "Files"
	_file_access_toggle.button_pressed = _get_setting("file_access", false)
	_file_access_toggle.tooltip_text = "Allow Claude to read project files (--add-dir + --dangerously-skip-permissions)"
	_file_access_toggle.toggled.connect(func(on: bool): _save_setting("file_access", on))
	row.add_child(_file_access_toggle)

	var preview_btn := Button.new()
	preview_btn.text = "Preview"
	preview_btn.flat = true
	preview_btn.tooltip_text = "Show the full context that will be sent to Claude"
	preview_btn.pressed.connect(_on_preview_context_pressed)
	row.add_child(preview_btn)

	_update_context_display()


func _build_settings_section() -> void:
	var toggle_btn := Button.new()
	toggle_btn.text = "Settings ▶"
	toggle_btn.flat = true
	toggle_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(toggle_btn)

	_settings_body = VBoxContainer.new()
	_settings_body.visible = false  # Collapsed by default
	_settings_body.add_theme_constant_override("separation", 5)
	_root_vbox.add_child(_settings_body)

	toggle_btn.pressed.connect(func():
		_settings_body.visible = not _settings_body.visible
		toggle_btn.text = "Settings ▼" if _settings_body.visible else "Settings ▶"
	)

	# ── Model selection ────────────────────────────────────────────────────
	var model_row := HBoxContainer.new()
	_settings_body.add_child(model_row)

	var model_lbl := Label.new()
	model_lbl.text = "Model:"
	model_lbl.custom_minimum_size.x = 52
	model_row.add_child(model_lbl)

	_model_option = OptionButton.new()
	_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var saved_model: String = _get_setting("model", "claude-sonnet-4-6")
	for i in _MODELS.size():
		_model_option.add_item(_MODELS[i][0], i)
		_model_option.set_item_metadata(i, _MODELS[i][1])
		if _MODELS[i][1] == saved_model:
			_model_option.select(i)
	_model_option.item_selected.connect(func(idx: int):
		_save_setting("model", _model_option.get_item_metadata(idx))
	)
	model_row.add_child(_model_option)

	# ── Custom system prompt ───────────────────────────────────────────────
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Custom prompt (prepended to all messages):"
	prompt_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settings_body.add_child(prompt_lbl)

	_custom_prompt_edit = TextEdit.new()
	_custom_prompt_edit.placeholder_text = (
		"e.g. \"My player uses a state machine in player_sm.gd.\n" +
		"Always use my EventBus autoload for signals.\""
	)
	_custom_prompt_edit.custom_minimum_size = Vector2(0, 60)
	_custom_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_custom_prompt_edit.text = _get_setting("custom_prompt", "")
	# Save on focus-lost to avoid writing EditorSettings on every keystroke.
	_custom_prompt_edit.focus_exited.connect(func():
		_save_setting("custom_prompt", _custom_prompt_edit.text)
	)
	_settings_body.add_child(_custom_prompt_edit)

	_settings_body.add_child(HSeparator.new())

	# ── Context section checkboxes ─────────────────────────────────────────
	var ctx_lbl := Label.new()
	ctx_lbl.text = "Context sections:"
	_settings_body.add_child(ctx_lbl)

	var grid := GridContainer.new()
	grid.columns = 2
	_settings_body.add_child(grid)

	_make_ctx_toggle(grid, "include_scene",         "Scene tree",    true)
	_make_ctx_toggle(grid, "include_selection",     "Selected node", true)
	_make_ctx_toggle(grid, "include_open_scripts",  "Open scripts",  true)
	_make_ctx_toggle(grid, "include_exports",       "Export vars",   true)
	_make_ctx_toggle(grid, "include_autoloads",     "Autoloads",     true)
	_make_ctx_toggle(grid, "include_input_map",     "Input map",     false)
	_make_ctx_toggle(grid, "include_animations",    "Animations",    true)
	_make_ctx_toggle(grid, "include_signals",       "Signals",       false)
	_make_ctx_toggle(grid, "include_script_source", "Script source", false)
	_make_ctx_toggle(grid, "include_open_scenes",   "Open scenes",   false)

	# Errors toggle + line count spinbox on the same row
	var errors_row := HBoxContainer.new()
	_settings_body.add_child(errors_row)
	_make_ctx_toggle(errors_row, "include_logs", "Errors  Lines:", false)
	_log_lines_spin = SpinBox.new()
	_log_lines_spin.min_value = 5
	_log_lines_spin.max_value = 100
	_log_lines_spin.step = 5
	_log_lines_spin.value = _get_setting("log_line_count", 20)
	_log_lines_spin.custom_minimum_size.x = 68
	_log_lines_spin.value_changed.connect(func(v: float): _save_setting("log_line_count", int(v)))
	errors_row.add_child(_log_lines_spin)

	# Scene tree depth spinbox
	var depth_row := HBoxContainer.new()
	_settings_body.add_child(depth_row)
	var depth_lbl := Label.new()
	depth_lbl.text = "Scene tree depth:"
	depth_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	depth_row.add_child(depth_lbl)
	_scene_depth_spin = SpinBox.new()
	_scene_depth_spin.min_value = 1
	_scene_depth_spin.max_value = 5
	_scene_depth_spin.value = _get_setting("scene_depth", 1)
	_scene_depth_spin.custom_minimum_size.x = 68
	_scene_depth_spin.value_changed.connect(func(v: float): _save_setting("scene_depth", int(v)))
	depth_row.add_child(_scene_depth_spin)


## Creates a CheckBox, registers it in _ctx_toggles, and adds it to parent.
func _make_ctx_toggle(parent: Control, key: String, label: String, default_val: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label
	cb.button_pressed = _get_setting(key, default_val)
	cb.toggled.connect(func(on: bool): _save_setting(key, on))
	parent.add_child(cb)
	_ctx_toggles[key] = cb
	return cb


func _build_chat_area() -> void:
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root_vbox.add_child(_scroll_container)

	_chat_vbox = VBoxContainer.new()
	_chat_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_vbox.add_theme_constant_override("separation", 6)
	_scroll_container.add_child(_chat_vbox)


func _build_status_bar() -> void:
	_status_label = Label.new()
	_status_label.text = "Checking for Claude Code..."
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_root_vbox.add_child(_status_label)


func _build_input_area() -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(hbox)

	_input_text = TextEdit.new()
	_input_text.placeholder_text = "Ask Claude... (Ctrl+Enter to send)"
	_input_text.custom_minimum_size = Vector2(0, 72)
	_input_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input_text.gui_input.connect(_on_input_gui_input)
	hbox.add_child(_input_text)

	var btn_col := VBoxContainer.new()
	hbox.add_child(btn_col)

	_send_button = Button.new()
	_send_button.text = "Send"
	_send_button.custom_minimum_size = Vector2(60, 0)
	_send_button.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_send_button.pressed.connect(_on_send_pressed)
	btn_col.add_child(_send_button)


# ---------------------------------------------------------------------------
# Install overlay (shown when claude CLI is not found)
# ---------------------------------------------------------------------------

func _show_install_ui(npm_available: bool) -> void:
	_clear_chat()

	# Bug fix 1.7: a stale session from a previous install is invalid — clear it.
	if _session_id != "":
		_session_id = ""
		_save_session_state()

	if is_instance_valid(_install_overlay):
		_install_overlay.queue_free()

	_install_overlay = PanelContainer.new()
	_install_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_install_overlay.add_child(vbox)

	var heading := Label.new()
	heading.text = "Claude Code Not Found"
	heading.add_theme_font_size_override("font_size", 14)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(heading)

	var desc := RichTextLabel.new()
	desc.bbcode_enabled = true
	desc.fit_content = true
	desc.scroll_active = false
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.text = (
		"[b]Claude Code[/b] is a free, open-source AI coding assistant by Anthropic.\n\n" +
		"It requires [b]Node.js[/b] (npm) to install."
	)
	vbox.add_child(desc)

	if not npm_available:
		var npm_warn := RichTextLabel.new()
		npm_warn.bbcode_enabled = true
		npm_warn.fit_content = true
		npm_warn.scroll_active = false
		npm_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		npm_warn.text = (
			"[color=#ff9966][b]npm not found.[/b][/color]\n\n" +
			"Please install Node.js first:\n[b]https://nodejs.org[/b]\n\n" +
			"After installing Node.js, restart Godot and try again."
		)
		vbox.add_child(npm_warn)
	else:
		var cmd_label := Label.new()
		cmd_label.text = "Install command:"
		vbox.add_child(cmd_label)

		var cmd_box := PanelContainer.new()
		vbox.add_child(cmd_box)
		var cmd_text := Label.new()
		cmd_text.text = "npm install -g @anthropic-ai/claude-code"
		cmd_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		cmd_box.add_child(cmd_text)

		if OS.get_name() not in ["Windows", "UWP"]:
			_sudo_check = CheckButton.new()
			_sudo_check.text = "Use sudo (if permission denied)"
			_sudo_check.button_pressed = false
			vbox.add_child(_sudo_check)

		_install_button = Button.new()
		_install_button.text = "Install Claude Code"
		_install_button.add_theme_font_size_override("font_size", 13)
		_install_button.pressed.connect(_on_install_pressed)
		vbox.add_child(_install_button)

	_install_status_label = RichTextLabel.new()
	_install_status_label.bbcode_enabled = true
	_install_status_label.fit_content = true
	_install_status_label.scroll_active = false
	_install_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_install_status_label.visible = false
	vbox.add_child(_install_status_label)

	_auth_button = Button.new()
	_auth_button.text = "Authenticate (claude auth login)"
	_auth_button.tooltip_text = "Opens a terminal to log in with your Anthropic account"
	_auth_button.visible = false
	_auth_button.pressed.connect(_on_auth_pressed)
	vbox.add_child(_auth_button)

	_chat_vbox.add_child(_install_overlay)
	_set_ui_busy(true)
	_send_button.tooltip_text = "Claude Code is not installed"
	_status_label.text = "Not installed"


func _hide_install_ui() -> void:
	if is_instance_valid(_install_overlay):
		_install_overlay.queue_free()
		_install_overlay = null
	_set_ui_busy(false)
	_send_button.tooltip_text = ""
	_status_label.text = "Ready"


# ---------------------------------------------------------------------------
# Install event handlers
# ---------------------------------------------------------------------------

func _on_install_pressed() -> void:
	if not is_instance_valid(_install_button):
		return
	_install_button.disabled = true
	_install_button.text = "Installing..."

	if is_instance_valid(_install_status_label):
		_install_status_label.visible = true
		_install_status_label.text = "[color=#aaaaaa]Starting installation...[/color]"

	var use_sudo := is_instance_valid(_sudo_check) and _sudo_check.button_pressed
	_runner.install_claude(use_sudo)


func _on_install_progress(message: String) -> void:
	if is_instance_valid(_install_status_label):
		_install_status_label.text = "[color=#aaaaaa]" + _escape_bbcode(message) + "[/color]"


func _on_install_finished(success: bool, message: String) -> void:
	if not is_instance_valid(_install_status_label):
		return
	_install_status_label.visible = true
	if success:
		_install_status_label.text = "[color=#88cc88]" + _escape_bbcode(message) + "[/color]"
		if is_instance_valid(_install_button):
			_install_button.visible = false
		if is_instance_valid(_auth_button):
			_auth_button.visible = true
	else:
		_install_status_label.text = "[color=#ff6b6b]" + _escape_bbcode(message) + "[/color]"
		if is_instance_valid(_install_button):
			_install_button.disabled = false
			_install_button.text = "Retry Installation"


func _on_auth_pressed() -> void:
	_runner.open_auth()
	# Bug fix 1.6: use CONNECT_ONE_SHOT and guard with is_instance_valid so the
	# callback is safely skipped if the panel is freed before the timer fires.
	get_tree().create_timer(3.0).timeout.connect(
		func():
			if is_instance_valid(self):
				_check_claude_installed_async(),
		CONNECT_ONE_SHOT
	)


# ---------------------------------------------------------------------------
# Async install check
# ---------------------------------------------------------------------------

func _check_claude_installed_async() -> void:
	if _install_check_thread != null and _install_check_thread.is_started():
		return
	_install_check_thread = Thread.new()
	_install_check_thread.start(_check_install_thread_fn)


func _check_install_thread_fn() -> void:
	var claude_ok := ClaudeRunner.check_installed()
	var npm_ok := true
	if not claude_ok:
		npm_ok = ClaudeRunner.check_npm_installed()
	call_deferred("_on_install_check_done", claude_ok, npm_ok)


func _on_install_check_done(claude_installed: bool, npm_available: bool) -> void:
	if _install_check_thread != null and _install_check_thread.is_started():
		_install_check_thread.wait_to_finish()
	_install_check_thread = null

	if claude_installed:
		_hide_install_ui()
		_status_label.text = "Ready"
		if _session_id != "":
			_add_system_message("Resumed session " + _session_id.left(8) + "...")
	else:
		_show_install_ui(npm_available)


# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and event.ctrl_pressed:
			_send_message()
			get_viewport().set_input_as_handled()


func _on_send_pressed() -> void:
	_send_message()


func _send_message() -> void:
	if _runner.is_running():
		return
	var text := _input_text.text.strip_edges()
	if text.is_empty():
		return

	_add_user_message(text)
	_input_text.text = ""
	_set_ui_busy(true)

	var context := ""
	if _include_context_toggle.button_pressed and is_instance_valid(editor_plugin):
		context = ContextBuilder.build(editor_plugin, _build_settings_dict())

	var project_dir := ""
	if _file_access_toggle.button_pressed:
		project_dir = ProjectSettings.globalize_path("res://")

	_runner.send(
		text, context, _session_id, project_dir,
		_file_access_toggle.button_pressed, _get_selected_model()
	)


## Assembles the settings dictionary passed to ContextBuilder.build().
func _build_settings_dict() -> Dictionary:
	var d: Dictionary = {}
	for key in _ctx_toggles:
		d[key] = (_ctx_toggles[key] as CheckBox).button_pressed
	d["custom_prompt"] = _custom_prompt_edit.text.strip_edges() if is_instance_valid(_custom_prompt_edit) else ""
	d["scene_depth"] = int(_scene_depth_spin.value) if is_instance_valid(_scene_depth_spin) else 1
	d["log_line_count"] = int(_log_lines_spin.value) if is_instance_valid(_log_lines_spin) else 20
	return d


func _get_selected_model() -> String:
	if not is_instance_valid(_model_option):
		return ""
	return _model_option.get_item_metadata(_model_option.selected)


# ---------------------------------------------------------------------------
# Context preview popup
# ---------------------------------------------------------------------------

func _on_preview_context_pressed() -> void:
	var context := ""
	if not is_instance_valid(editor_plugin):
		context = "(Editor plugin reference not available)"
	elif not _include_context_toggle.button_pressed:
		context = "(Context injection is disabled — enable 'Include context' to send editor state)"
	else:
		context = ContextBuilder.build(editor_plugin, _build_settings_dict())
	if context.is_empty():
		context = "(No context — all sections are disabled or returned empty)"

	var dialog := AcceptDialog.new()
	dialog.title = "Context Preview — What Claude Will Receive"
	dialog.min_size = Vector2(640, 500)

	var text_edit := TextEdit.new()
	text_edit.text = context
	text_edit.editable = false
	text_edit.custom_minimum_size = Vector2(620, 440)
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dialog.add_child(text_edit)

	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free, CONNECT_ONE_SHOT)
	dialog.canceled.connect(dialog.queue_free, CONNECT_ONE_SHOT)


# ---------------------------------------------------------------------------
# Runner signal handlers
# ---------------------------------------------------------------------------

func _on_request_started() -> void:
	_status_label.text = "Thinking..."


func _on_response_received(text: String, session_id: String) -> void:
	_set_ui_busy(false)
	_status_label.text = "Ready"
	if session_id != "":
		_session_id = session_id
		_save_session_state()
	_add_claude_message(text)


func _on_error_occurred(message: String) -> void:
	_set_ui_busy(false)
	_status_label.text = "Error"
	_add_error_message(message)


# ---------------------------------------------------------------------------
# Chat bubble rendering
# ---------------------------------------------------------------------------

func _add_user_message(text: String) -> void:
	_add_chat_bubble(text, "user")


func _add_claude_message(text: String) -> void:
	_add_chat_bubble(text, "claude")


func _add_error_message(text: String) -> void:
	_add_chat_bubble(text, "error")


func _add_system_message(text: String) -> void:
	_add_chat_bubble(text, "system")


func _add_chat_bubble(text: String, msg_type: String) -> void:
	var container := PanelContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.selection_enabled = true

	match msg_type:
		"user":
			label.text = "[color=#7ec8e3][b]You[/b][/color]\n" + _escape_bbcode(text)
		"claude":
			label.text = "[color=#a8d5a2][b]Claude[/b][/color]\n" + _markdown_to_bbcode(text)
		"error":
			label.text = "[color=#ff6b6b][b]Error[/b][/color]\n" + _escape_bbcode(text)
		"system":
			label.text = "[color=#888888][i]" + _escape_bbcode(text) + "[/i][/color]"

	container.add_child(label)
	_chat_vbox.add_child(container)
	call_deferred("_do_scroll_to_bottom")


func _do_scroll_to_bottom() -> void:
	if not is_instance_valid(_scroll_container):
		return
	await get_tree().process_frame
	if is_instance_valid(_scroll_container):
		_scroll_container.scroll_vertical = int(_scroll_container.get_v_scroll_bar().max_value)


# ---------------------------------------------------------------------------
# Text formatting: Markdown to BBCode
# ---------------------------------------------------------------------------

func _compile_regexes() -> void:
	_re_code_block = RegEx.new()
	_re_code_block.compile("```(?:[a-zA-Z0-9]*)?\n([\\s\\S]*?)```")
	_re_inline_code = RegEx.new()
	_re_inline_code.compile("`([^`\n]+)`")
	_re_bold = RegEx.new()
	_re_bold.compile("\\*\\*([^*\n]+)\\*\\*")
	_re_italic = RegEx.new()
	_re_italic.compile("(?<![*])\\*([^*\n]+)\\*(?![*])")


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


func _markdown_to_bbcode(text: String) -> String:
	var result := text
	result = _re_code_block.sub(result, "[code]$1[/code]", true)
	result = _re_inline_code.sub(result, "[code]$1[/code]", true)
	result = _re_bold.sub(result, "[b]$1[/b]", true)
	result = _re_italic.sub(result, "[i]$1[/i]", true)

	var lines := result.split("\n")
	var out: Array[String] = []
	for line in lines:
		if line.begins_with("### "):
			out.append("[b]" + line.substr(4) + "[/b]")
		elif line.begins_with("## "):
			out.append("[b]" + line.substr(3) + "[/b]")
		elif line.begins_with("# "):
			out.append("[b]" + line.substr(2) + "[/b]")
		elif line.begins_with("- ") or line.begins_with("* "):
			out.append("  \u2022 " + line.substr(2))
		elif line.begins_with("    - ") or line.begins_with("    * "):
			out.append("    \u25e6 " + line.substr(6))
		else:
			out.append(line)

	return "\n".join(out)


# ---------------------------------------------------------------------------
# UI state helpers
# ---------------------------------------------------------------------------

func _set_ui_busy(busy: bool) -> void:
	if is_instance_valid(_send_button):
		_send_button.disabled = busy
	if is_instance_valid(_input_text):
		_input_text.editable = not busy
	if is_instance_valid(_new_chat_button):
		_new_chat_button.disabled = busy


func _on_new_chat_pressed() -> void:
	_session_id = ""
	_save_session_state()
	_clear_chat()
	_add_system_message("New conversation started.")
	_status_label.text = "Ready"


func _on_clear_pressed() -> void:
	_clear_chat()


func _clear_chat() -> void:
	if not is_instance_valid(_chat_vbox):
		return
	for child in _chat_vbox.get_children():
		child.queue_free()
	_install_overlay = null


func _update_context_display() -> void:
	if not is_instance_valid(_context_info_label) or not is_instance_valid(editor_plugin):
		return
	_context_info_label.text = ContextBuilder.get_status_line(editor_plugin)


# ---------------------------------------------------------------------------
# Settings persistence (EditorSettings project metadata)
# ---------------------------------------------------------------------------

func _get_setting(key: String, default_val: Variant) -> Variant:
	if not is_instance_valid(editor_plugin):
		return default_val
	return editor_plugin.get_editor_interface().get_editor_settings() \
		.get_project_metadata(_SETTINGS_KEY, key, default_val)


func _save_setting(key: String, value: Variant) -> void:
	if not is_instance_valid(editor_plugin):
		return
	editor_plugin.get_editor_interface().get_editor_settings() \
		.set_project_metadata(_SETTINGS_KEY, key, value)


func _save_session_state() -> void:
	_save_setting("session_id", _session_id)


func _load_session_state() -> void:
	_session_id = _get_setting("session_id", "")
