## Handles cross-platform execution of the Claude Code CLI in a background thread.
## All UI interaction must happen via signals emitted with call_deferred().
@tool
class_name ClaudeRunner
extends RefCounted

signal response_received(text: String, session_id: String)
signal error_occurred(message: String)
signal request_started()
signal install_progress(message: String)
signal install_finished(success: bool, message: String)
signal stream_chunk(text: String)
signal stream_finished(session_id: String)

var _thread: Thread = null
var _is_running: bool = false
var _aborted: bool = false

# Streaming state
var _stream_pid: int = -1
var _stream_out_path: String = ""
var _stream_read_pos: int = 0
var _stream_partial: String = ""
var _stream_accumulated: String = ""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func is_running() -> bool:
	return _is_running


func send(
	user_message: String,
	context_prompt: String,
	session_id: String,
	project_dir: String,
	allow_file_access: bool,
	model: String = ""
) -> void:
	if _is_running:
		push_warning("ClaudeRunner: request already in progress, ignoring.")
		return

	_aborted = false
	_is_running = true
	request_started.emit()

	_join_thread()

	# Bug fix 1.5: call the static directly; the non-static wrapper was redundant.
	var exe_info := _get_claude_exe_info_static()
	var args := _build_send_args(
		exe_info.prefix, user_message, context_prompt,
		session_id, project_dir, allow_file_access, model
	)

	_thread = Thread.new()
	_thread.start(_run_send_blocking.bind(exe_info.exe, args))


func install_claude(use_sudo: bool = false) -> void:
	if _is_running:
		return

	_is_running = true
	_join_thread()

	_thread = Thread.new()
	_thread.start(_run_install_blocking.bind(use_sudo))


func open_auth() -> void:
	## Opens a terminal window running 'claude auth login'.
	## Uses OS.create_process so it opens visibly in a new window.
	var platform := OS.get_name()
	match platform:
		"Windows", "UWP":
			OS.create_process("cmd.exe", ["/c", "start", "cmd.exe", "/k", "claude auth login"])
		"macOS":
			OS.create_process("osascript", [
				"-e", 'tell app "Terminal" to do script "claude auth login"'
			])
		_:
			# Linux: try common terminal emulators in order of preference
			for term in ["x-terminal-emulator", "gnome-terminal", "xterm", "konsole", "xfce4-terminal"]:
				var pid := OS.create_process(term, ["--", "bash", "-c", "claude auth login; read -p 'Press Enter to close...'"])
				if pid > 0:
					return
			# Last resort: run detached in background (no visible window)
			OS.create_process("bash", ["-c", "claude auth login"])


## Cancels any in-flight request. For streaming, kills the process.
## For the blocking thread path, marks the response to be discarded on arrival.
func abort() -> void:
	_aborted = true
	if _stream_pid > 0:
		if OS.is_process_running(_stream_pid):
			OS.kill(_stream_pid)
		_stream_pid = -1
	_is_running = false


## Starts claude as a background process with stdout piped to a temp file.
## Returns true on success; false on Windows (caller should use send() instead).
func start_stream(
	user_message: String,
	context_prompt: String,
	session_id: String,
	project_dir: String,
	allow_file_access: bool,
	model: String = ""
) -> bool:
	if _is_running:
		return false
	if OS.get_name() in ["Windows", "UWP"]:
		return false  # streaming via bash not available on Windows

	_aborted = false
	_is_running = true
	_stream_accumulated = ""
	_stream_read_pos = 0
	_stream_partial = ""
	request_started.emit()

	var out_path := OS.get_user_data_dir() + "/claude_godot_stream.tmp"
	var script_path := OS.get_user_data_dir() + "/claude_godot_run.sh"
	_stream_out_path = out_path

	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	# Build the claude args (no platform prefix — bash will find claude on PATH)
	var args := _build_send_args([], user_message, context_prompt,
		session_id, project_dir, allow_file_access, model)

	# Write a bash script so arg values are never interpolated by a shell.
	# Export Godot's own PATH so the same 'claude' that check_installed() found
	# is reachable in the non-login bash subprocess.
	var env_path := OS.get_environment("PATH")
	var cmd := "export PATH=" + _bash_single_quote(env_path) + "\n"
	cmd += "claude"
	for a: String in args:
		cmd += " " + _bash_single_quote(a)
	cmd += " > " + _bash_single_quote(out_path)

	var sf := FileAccess.open(script_path, FileAccess.WRITE)
	if sf == null:
		_is_running = false
		return false
	sf.store_string("#!/bin/bash\n" + cmd + "\n")
	sf.close()

	_stream_pid = OS.create_process("bash", [script_path])
	if _stream_pid <= 0:
		_is_running = false
		return false

	return true


## Called by a Timer in ClaudePanel every ~100 ms to read new output.
func poll_stream() -> void:
	if not _is_running:
		return

	if FileAccess.file_exists(_stream_out_path):
		var f := FileAccess.open(_stream_out_path, FileAccess.READ)
		if f != null:
			var file_len := f.get_length()
			if file_len > _stream_read_pos:
				f.seek(_stream_read_pos)
				var new_bytes := f.get_buffer(file_len - _stream_read_pos)
				_stream_read_pos = file_len
				f.close()
				_ingest_stream_bytes(new_bytes.get_string_from_utf8())
			else:
				f.close()

	if _stream_pid > 0 and not OS.is_process_running(_stream_pid):
		_stream_pid = -1
		_do_final_stream_read()


func _ingest_stream_bytes(new_content: String) -> void:
	var to_parse := _stream_partial + new_content
	var lines := to_parse.split("\n")
	# If content doesn't end with \n, the last element is an incomplete line
	if to_parse.ends_with("\n"):
		_stream_partial = ""
	else:
		_stream_partial = lines[-1]
		lines.resize(lines.size() - 1)
	for line: String in lines:
		var trimmed := line.strip_edges()
		if not trimmed.is_empty():
			_parse_ndjson_line(trimmed)


func _parse_ndjson_line(line: String) -> void:
	var parsed = JSON.parse_string(line)
	if not parsed is Dictionary:
		return
	match parsed.get("type", ""):
		"assistant":
			# The Claude Code CLI emits progressive "assistant" events whose
			# message.content[0].text grows with each chunk — emit only the delta.
			var msg = parsed.get("message", {})
			if msg is Dictionary:
				var content = msg.get("content", [])
				if content is Array and content.size() > 0:
					var block = content[0]
					if block is Dictionary and block.get("type") == "text":
						var full_text: String = block.get("text", "")
						if full_text.length() > _stream_accumulated.length():
							var new_chunk := full_text.substr(_stream_accumulated.length())
							_stream_accumulated = full_text
							stream_chunk.emit(new_chunk)
		"content_block_delta":
			# Anthropic API delta format — kept as fallback
			var delta = parsed.get("delta", {})
			if delta is Dictionary and delta.get("type") == "text_delta":
				var chunk: String = delta.get("text", "")
				if not chunk.is_empty():
					_stream_accumulated += chunk
					stream_chunk.emit(chunk)
		"result":
			if parsed.get("is_error", false):
				_is_running = false
				error_occurred.emit(parsed.get("result", "Unknown error from Claude."))
			else:
				# If no streaming events produced text, use the final result field
				if _stream_accumulated.is_empty():
					var result_text: String = parsed.get("result", "")
					if not result_text.is_empty():
						_stream_accumulated = result_text
						stream_chunk.emit(result_text)
				_is_running = false
				stream_finished.emit(parsed.get("session_id", ""))


func _do_final_stream_read() -> void:
	# One last read to catch any bytes written after our previous poll
	if FileAccess.file_exists(_stream_out_path):
		var f := FileAccess.open(_stream_out_path, FileAccess.READ)
		if f != null:
			var file_len := f.get_length()
			if file_len > _stream_read_pos:
				f.seek(_stream_read_pos)
				var new_bytes := f.get_buffer(file_len - _stream_read_pos)
				_stream_read_pos = file_len
				f.close()
				_ingest_stream_bytes(new_bytes.get_string_from_utf8())
			else:
				f.close()

	# Flush any partial line
	if not _stream_partial.strip_edges().is_empty():
		_parse_ndjson_line(_stream_partial.strip_edges())
		_stream_partial = ""

	# If no result event was ever received, synthesise an error
	if _is_running:
		_is_running = false
		if _stream_accumulated.is_empty():
			error_occurred.emit(
				"Claude returned no output.\n\nMake sure you are authenticated:\n  claude auth login"
			)
		else:
			stream_finished.emit("")


static func _bash_single_quote(s: String) -> String:
	## Wraps s in bash single quotes; internal single quotes are escaped as '\''
	return "'" + s.replace("'", "'\\''") + "'"


func cleanup() -> void:
	## Must be called before queue_free() to safely join any running thread.
	if _stream_pid > 0:
		if OS.is_process_running(_stream_pid):
			OS.kill(_stream_pid)
		_stream_pid = -1
	_is_running = false
	_join_thread()


# ---------------------------------------------------------------------------
# Installation check (static — can be called without an instance)
# ---------------------------------------------------------------------------

static func check_installed() -> bool:
	var exe_info := _get_claude_exe_info_static()
	var args: Array = exe_info.prefix.duplicate()
	args.append("--version")
	var output: Array = []
	var exit_code := OS.execute(exe_info.exe, args, output)
	return exit_code == 0


static func check_npm_installed() -> bool:
	var platform := OS.get_name()
	var output: Array = []
	if platform in ["Windows", "UWP"]:
		return OS.execute("cmd.exe", ["/c", "npm", "--version"], output) == 0
	else:
		return OS.execute("npm", ["--version"], output) == 0


# ---------------------------------------------------------------------------
# Cross-platform executable info
# ---------------------------------------------------------------------------

static func _get_claude_exe_info_static() -> Dictionary:
	var platform := OS.get_name()
	if platform in ["Windows", "UWP"]:
		return {"exe": "cmd.exe", "prefix": ["/c", "claude"]}
	else:
		return {"exe": "claude", "prefix": []}


# ---------------------------------------------------------------------------
# Argument construction for send()
# ---------------------------------------------------------------------------

func _build_send_args(
	prefix: Array,
	message: String,
	context: String,
	session_id: String,
	project_dir: String,
	allow_files: bool,
	model: String = ""
) -> Array:
	var args: Array = prefix.duplicate()
	args.append_array(["--print", "--output-format", "stream-json", "--verbose"])

	if model != "":
		args.append_array(["--model", model])

	if context != "":
		args.append_array(["--append-system-prompt", context])

	if allow_files and project_dir != "":
		args.append_array(["--add-dir", project_dir])
		# --print mode cannot show interactive permission prompts
		args.append("--dangerously-skip-permissions")

	if session_id != "":
		args.append_array(["--resume", session_id])

	# User message is the final positional argument
	args.append(message)
	return args


# ---------------------------------------------------------------------------
# Thread workers
# ---------------------------------------------------------------------------

func _run_send_blocking(exe: String, args: Array) -> void:
	var output: Array = []
	# read_stderr=false: avoids mixing ANSI escape sequences into our JSON stream
	var exit_code := OS.execute(exe, args, output, false)
	call_deferred("_on_send_done", exit_code, output)


func _run_install_blocking(use_sudo: bool) -> void:
	var platform := OS.get_name()

	# Build install command
	var cmd: String
	if use_sudo and platform not in ["Windows", "UWP"]:
		cmd = "sudo npm install -g @anthropic-ai/claude-code"
	else:
		cmd = "npm install -g @anthropic-ai/claude-code"

	call_deferred("_emit_install_progress", "Running: " + cmd + "\n\nThis may take a minute...")

	var output: Array = []
	var exit_code: int
	if platform in ["Windows", "UWP"]:
		exit_code = OS.execute("cmd.exe", ["/c", cmd], output)
	else:
		exit_code = OS.execute("bash", ["-c", cmd], output)

	var out_text: String = output[0] if output.size() > 0 else ""

	if exit_code == 0:
		# Verify the install actually worked
		var verify_ok := check_installed()
		if verify_ok:
			call_deferred("_on_install_done", true,
				"Claude Code installed successfully!\n\nClick 'Authenticate' to log in with your Anthropic account.")
		else:
			call_deferred("_on_install_done", false,
				"npm completed but 'claude' was not found in PATH.\n\n" +
				"You may need to restart your terminal or Godot.\n\nOutput:\n" + out_text)
	else:
		var err_msg := "Installation failed (exit code: %d).\n\n" % exit_code
		if "EACCES" in out_text or "permission denied" in out_text.to_lower():
			err_msg += "Permission denied. Try enabling 'Use sudo' and installing again.\n\n"
		elif "npm: not found" in out_text or "npm: command not found" in out_text:
			err_msg += "npm was not found. Please install Node.js first:\nhttps://nodejs.org\n\n"
		err_msg += "Output:\n" + out_text
		call_deferred("_on_install_done", false, err_msg)


# ---------------------------------------------------------------------------
# Deferred callbacks (called on main thread)
# ---------------------------------------------------------------------------

func _emit_install_progress(message: String) -> void:
	install_progress.emit(message)


func _on_send_done(exit_code: int, output: Array) -> void:
	_is_running = false

	if _aborted:
		_aborted = false
		return  # request was cancelled; discard response silently

	if exit_code == -1:
		error_occurred.emit(
			"Could not launch the Claude CLI.\n\n" +
			"Make sure it is installed and on your PATH.\n" +
			"Use the 'Install' button below, or run manually:\n\n" +
			"  npm install -g @anthropic-ai/claude-code\n\n" +
			"Restart Godot after installation to refresh PATH."
		)
		return

	var raw: String = output[0] if output.size() > 0 else ""
	if raw.is_empty():
		error_occurred.emit(
			"Claude returned no output (exit code: %d).\n\n" % exit_code +
			"Make sure you are authenticated:\n  claude auth login"
		)
		return

	var result := _parse_stream_json(raw)
	if result.is_error:
		error_occurred.emit("Claude error: " + result.text)
	elif result.text.is_empty():
		error_occurred.emit(
			"Claude returned an empty response.\nExit code: %d" % exit_code
		)
	else:
		response_received.emit(result.text, result.session_id)


func _on_install_done(success: bool, message: String) -> void:
	_is_running = false
	install_finished.emit(success, message)


# ---------------------------------------------------------------------------
# Stream-JSON output parsing
# ---------------------------------------------------------------------------

func _parse_stream_json(raw: String) -> Dictionary:
	## Scans newline-delimited JSON for the {"type":"result"} event.
	## That event contains: "result" (clean final text) and "session_id" (UUID).
	var out := {"text": "", "session_id": "", "is_error": false}

	for line in raw.split("\n"):
		line = line.strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if not parsed is Dictionary:
			continue
		if parsed.get("type") != "result":
			continue
		out.session_id = parsed.get("session_id", "")
		if parsed.get("is_error", false):
			out.is_error = true
			out.text = parsed.get("result", "Unknown error from Claude.")
		else:
			out.text = parsed.get("result", "")
		break  # Only one "result" event per invocation

	return out


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _join_thread() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
