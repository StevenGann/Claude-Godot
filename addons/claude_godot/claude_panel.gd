## Main docked panel for the Claude Godot plugin.
## Builds its entire UI programmatically (no .tscn dependency).
@tool
extends Control

## Set by plugin.gd before this control is added to the dock.
var editor_plugin: EditorPlugin

# ---------------------------------------------------------------------------
# Child node references (populated in _build_ui)
# ---------------------------------------------------------------------------
var _root_vbox: VBoxContainer
var _scroll_container: ScrollContainer
var _chat_vbox: VBoxContainer
var _input_text: TextEdit
var _send_button: Button
var _new_chat_button: Button
var _status_label: Label
var _context_info_label: RichTextLabel
var _context_section: VBoxContainer
var _include_context_toggle: CheckButton
var _include_logs_toggle: CheckButton
var _file_access_toggle: CheckButton

# Install UI (shown when claude isn't installed)
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


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	name = "Claude"
	custom_minimum_size = Vector2(240, 400)

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
	var header := HBoxContainer.new()
	_root_vbox.add_child(header)

	var toggle_btn := Button.new()
	toggle_btn.text = "Context ▼"
	toggle_btn.flat = true
	toggle_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(toggle_btn)

	_context_section = VBoxContainer.new()
	_context_section.add_theme_constant_override("separation", 3)
	_root_vbox.add_child(_context_section)

	toggle_btn.pressed.connect(func():
		_context_section.visible = not _context_section.visible
		toggle_btn.text = "Context ▼" if _context_section.visible else "Context ▶"
	)

	# Scene / selection status line
	_context_info_label = RichTextLabel.new()
	_context_info_label.bbcode_enabled = false
	_context_info_label.fit_content = true
	_context_info_label.scroll_active = false
	_context_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_context_info_label.custom_minimum_size.y = 32
	_context_section.add_child(_context_info_label)

	# Toggle options row 1
	var row1 := HBoxContainer.new()
	_context_section.add_child(row1)

	_include_context_toggle = CheckButton.new()
	_include_context_toggle.text = "Include context"
	_include_context_toggle.button_pressed = true
	_include_context_toggle.tooltip_text = "Send scene/node context with each message"
	row1.add_child(_include_context_toggle)

	_include_logs_toggle = CheckButton.new()
	_include_logs_toggle.text = "Errors"
	_include_logs_toggle.button_pressed = false
	_include_logs_toggle.tooltip_text = "Include recent errors from the Godot log file"
	row1.add_child(_include_logs_toggle)

	# Toggle options row 2
	var row2 := HBoxContainer.new()
	_context_section.add_child(row2)

	_file_access_toggle = CheckButton.new()
	_file_access_toggle.text = "File access"
	_file_access_toggle.button_pressed = false
	_file_access_toggle.tooltip_text = (
		"Allow Claude to read your project files.\n" +
		"Uses --add-dir and --dangerously-skip-permissions."
	)
	row2.add_child(_file_access_toggle)

	_update_context_display()


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
# Install overlay (replaces chat content when claude is missing)
# ---------------------------------------------------------------------------

func _show_install_ui(npm_available: bool) -> void:
	# Clear any existing chat content first
	_clear_chat()

	# Remove old overlay if present
	if is_instance_valid(_install_overlay):
		_install_overlay.queue_free()

	_install_overlay = PanelContainer.new()
	_install_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_install_overlay.add_child(vbox)

	# Heading
	var heading := Label.new()
	heading.text = "Claude Code Not Found"
	heading.add_theme_font_size_override("font_size", 14)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(heading)

	# Description
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
		# npm missing — show Node.js install instruction
		var npm_warn := RichTextLabel.new()
		npm_warn.bbcode_enabled = true
		npm_warn.fit_content = true
		npm_warn.scroll_active = false
		npm_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		npm_warn.text = (
			"[color=#ff9966][b]npm not found.[/b][/color]\n\n" +
			"Please install Node.js first:\n[b]https://nodejs.org[/b]\n\n" +
			"After installing Node.js, restart Godot and this panel will offer to install Claude Code."
		)
		vbox.add_child(npm_warn)
	else:
		# npm available — show install option
		var cmd_label := Label.new()
		cmd_label.text = "Install command:"
		vbox.add_child(cmd_label)

		var cmd_box := PanelContainer.new()
		vbox.add_child(cmd_box)
		var cmd_text := Label.new()
		cmd_text.text = "npm install -g @anthropic-ai/claude-code"
		cmd_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		cmd_box.add_child(cmd_text)

		# sudo option (Linux/macOS only)
		if OS.get_name() not in ["Windows", "UWP"]:
			_sudo_check = CheckButton.new()
			_sudo_check.text = "Use sudo (if permission denied)"
			_sudo_check.button_pressed = false
			vbox.add_child(_sudo_check)

		# Install button
		_install_button = Button.new()
		_install_button.text = "Install Claude Code"
		_install_button.add_theme_font_size_override("font_size", 13)
		_install_button.pressed.connect(_on_install_pressed)
		vbox.add_child(_install_button)

	# Status / progress label (hidden until install starts)
	_install_status_label = RichTextLabel.new()
	_install_status_label.bbcode_enabled = true
	_install_status_label.fit_content = true
	_install_status_label.scroll_active = false
	_install_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_install_status_label.visible = false
	vbox.add_child(_install_status_label)

	# Auth button (hidden until install succeeds)
	_auth_button = Button.new()
	_auth_button.text = "Authenticate (claude auth login)"
	_auth_button.tooltip_text = "Opens a terminal to log in with your Anthropic account"
	_auth_button.visible = false
	_auth_button.pressed.connect(_on_auth_pressed)
	vbox.add_child(_auth_button)

	_chat_vbox.add_child(_install_overlay)

	# Disable chat input while not installed
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

	var use_sudo := false
	if is_instance_valid(_sudo_check):
		use_sudo = _sudo_check.button_pressed

	_runner.install_claude(use_sudo)


func _on_install_progress(message: String) -> void:
	if is_instance_valid(_install_status_label):
		_install_status_label.text = "[color=#aaaaaa]" + _escape_bbcode(message) + "[/color]"


func _on_install_finished(success: bool, message: String) -> void:
	if is_instance_valid(_install_status_label):
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
	# After auth they need to re-verify, so re-check after a short delay
	get_tree().create_timer(3.0).timeout.connect(_check_claude_installed_async)


# ---------------------------------------------------------------------------
# Async install check (runs in background thread at startup)
# ---------------------------------------------------------------------------

func _check_claude_installed_async() -> void:
	if _install_check_thread != null and _install_check_thread.is_started():
		return  # Already checking

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
		context = ContextBuilder.build(editor_plugin, _include_logs_toggle.button_pressed)

	var project_dir := ""
	if _file_access_toggle.button_pressed:
		project_dir = ProjectSettings.globalize_path("res://")

	_runner.send(text, context, _session_id, project_dir, _file_access_toggle.button_pressed)


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
	label.selection_enabled = true  # Allow copy-paste

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

	# Scroll to bottom after the frame so layout is computed
	_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	# Use call_deferred so the layout is computed before we scroll
	call_deferred("_do_scroll_to_bottom")


func _do_scroll_to_bottom() -> void:
	if is_instance_valid(_scroll_container):
		await get_tree().process_frame
		_scroll_container.scroll_vertical = int(_scroll_container.get_v_scroll_bar().max_value)


# ---------------------------------------------------------------------------
# Text formatting: Markdown → BBCode
# ---------------------------------------------------------------------------

func _escape_bbcode(text: String) -> String:
	## Prevents user/response text from being interpreted as BBCode.
	return text.replace("[", "[lb]")


func _markdown_to_bbcode(text: String) -> String:
	var result := text

	# Fenced code blocks (``` ... ```) — process before inline code
	var code_block_re := RegEx.new()
	code_block_re.compile("```(?:[a-zA-Z0-9]*)?\n([\\s\\S]*?)```")
	result = code_block_re.sub(result, "[code]$1[/code]", true)

	# Inline code (backtick)
	var inline_code_re := RegEx.new()
	inline_code_re.compile("`([^`\n]+)`")
	result = inline_code_re.sub(result, "[code]$1[/code]", true)

	# Bold (**text**)
	var bold_re := RegEx.new()
	bold_re.compile("\\*\\*([^*\n]+)\\*\\*")
	result = bold_re.sub(result, "[b]$1[/b]", true)

	# Italic (*text*) — single asterisk, not preceded/followed by another
	var italic_re := RegEx.new()
	italic_re.compile("(?<![*])\\*([^*\n]+)\\*(?![*])")
	result = italic_re.sub(result, "[i]$1[/i]", true)

	# Process line by line for headers and list items
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
			out.append("  • " + line.substr(2))
		elif line.begins_with("    - ") or line.begins_with("    * "):
			out.append("    ◦ " + line.substr(6))
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
	# Reset install overlay reference if it was a child
	_install_overlay = null


func _update_context_display() -> void:
	if not is_instance_valid(_context_info_label):
		return
	if not is_instance_valid(editor_plugin):
		_context_info_label.text = "Editor not available"
		return
	_context_info_label.text = ContextBuilder.get_status_line(editor_plugin)


# ---------------------------------------------------------------------------
# Session persistence (EditorSettings project metadata)
# ---------------------------------------------------------------------------

func _save_session_state() -> void:
	if not is_instance_valid(editor_plugin):
		return
	var es := editor_plugin.get_editor_interface().get_editor_settings()
	es.set_project_metadata(_SETTINGS_KEY, "session_id", _session_id)


func _load_session_state() -> void:
	if not is_instance_valid(editor_plugin):
		return
	var es := editor_plugin.get_editor_interface().get_editor_settings()
	_session_id = es.get_project_metadata(_SETTINGS_KEY, "session_id", "")
