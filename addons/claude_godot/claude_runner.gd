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
## Emitted whenever a usage payload is seen (message_start, message_delta, result).
## Keys (all optional): input_tokens, output_tokens, cache_read_input_tokens,
## cache_creation_input_tokens, total_cost_usd, model, context_window,
## max_output_tokens, rate_limit (Dictionary), is_final (bool).
signal usage_updated(usage: Dictionary)
## Emitted once per run with the detected CLI version, read from system/init.
signal cli_version_detected(version: String)

var _thread: Thread = null
var _is_running: bool = false
var _aborted: bool = false

# Streaming state
var _stream_pid: int = -1
var _stream_out_path: String = ""
var _stream_read_pos: int = 0
var _stream_partial: String = ""
var _stream_accumulated: String = ""   # used by legacy assistant-event fallback

# Delta-stream state (--include-partial-messages path)
var _got_stream_event: bool = false    # if true, ignore legacy assistant/delta branches
var _current_block_type: String = ""   # "text", "thinking", "tool_use", or ""
var _text_blocks_emitted: int = 0      # for inserting blank lines between text blocks
var _stream_text_accumulated: String = ""  # final text for history; built from text_deltas
var _last_model_id: String = ""        # captured from system/init for usage


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
	model: String = "",
	effort: String = ""
) -> void:
	if _is_running:
		push_warning("ClaudeRunner: request already in progress, ignoring.")
		return

	_aborted = false
	_is_running = true
	_reset_stream_state()
	request_started.emit()

	_join_thread()

	# Bug fix 1.5: call the static directly; the non-static wrapper was redundant.
	var exe_info := _get_claude_exe_info_static()
	var args := _build_send_args(
		exe_info.prefix, user_message, context_prompt,
		session_id, project_dir, allow_file_access, model, effort
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
	model: String = "",
	effort: String = ""
) -> bool:
	if _is_running:
		return false
	if OS.get_name() in ["Windows", "UWP"]:
		return false  # streaming via bash not available on Windows

	_aborted = false
	_is_running = true
	_reset_stream_state()
	request_started.emit()

	var out_path := OS.get_user_data_dir() + "/claude_godot_stream.tmp"
	var script_path := OS.get_user_data_dir() + "/claude_godot_run.sh"
	_stream_out_path = out_path

	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	# Build the claude args (no platform prefix — bash will find claude on PATH)
	var args := _build_send_args([], user_message, context_prompt,
		session_id, project_dir, allow_file_access, model, effort)

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
		"system":
			_handle_system_event(parsed)
		"stream_event":
			# Claude Code 2.x with --include-partial-messages emits Anthropic-
			# style content_block_delta events wrapped inside stream_event.
			_got_stream_event = true
			var ev = parsed.get("event", {})
			if ev is Dictionary:
				_handle_stream_event(ev)
		"assistant":
			# LEGACY path — only used if the CLI never produced a stream_event
			# (older CLI versions or --include-partial-messages unsupported).
			if _got_stream_event:
				return
			_handle_legacy_assistant(parsed)
		"content_block_delta":
			# LEGACY fallback for very old CLIs that emitted Anthropic deltas
			# directly at the top level.
			if _got_stream_event:
				return
			var delta = parsed.get("delta", {})
			if delta is Dictionary and delta.get("type") == "text_delta":
				var chunk: String = delta.get("text", "")
				if not chunk.is_empty():
					_stream_accumulated += chunk
					_stream_text_accumulated += chunk
					stream_chunk.emit(chunk)
		"rate_limit_event":
			var info = parsed.get("rate_limit_info", {})
			if info is Dictionary:
				usage_updated.emit({"rate_limit": info})
		"result":
			_handle_result_event(parsed)


func _handle_system_event(parsed: Dictionary) -> void:
	match parsed.get("subtype", ""):
		"init":
			var version: String = parsed.get("claude_code_version", "")
			if version != "":
				cli_version_detected.emit(version)
			var mdl: String = parsed.get("model", "")
			if mdl != "":
				_last_model_id = mdl


func _handle_stream_event(ev: Dictionary) -> void:
	match ev.get("type", ""):
		"message_start":
			var msg = ev.get("message", {})
			if msg is Dictionary:
				var mdl: String = msg.get("model", "")
				if mdl != "":
					_last_model_id = mdl
				var u = msg.get("usage", {})
				if u is Dictionary:
					var payload := _make_usage_payload(u, false)
					if _last_model_id != "":
						payload["model"] = _last_model_id
					usage_updated.emit(payload)
		"content_block_start":
			var cb = ev.get("content_block", {})
			var block_type: String = ""
			if cb is Dictionary:
				block_type = cb.get("type", "")
			_current_block_type = block_type
			# Insert a paragraph break between consecutive text blocks
			# (there may be a thinking / tool_use block between them).
			if block_type == "text" and _text_blocks_emitted > 0:
				stream_chunk.emit("\n\n")
				_stream_text_accumulated += "\n\n"
		"content_block_delta":
			var delta = ev.get("delta", {})
			if not delta is Dictionary:
				return
			match delta.get("type", ""):
				"text_delta":
					var chunk: String = delta.get("text", "")
					if not chunk.is_empty():
						_stream_text_accumulated += chunk
						stream_chunk.emit(chunk)
				"thinking_delta", "signature_delta", "input_json_delta":
					# Reasoning/tool-args deltas are not surfaced to chat.
					pass
		"content_block_stop":
			if _current_block_type == "text":
				_text_blocks_emitted += 1
			_current_block_type = ""
		"message_delta":
			var u = ev.get("usage", {})
			if u is Dictionary:
				var payload := _make_usage_payload(u, false)
				if _last_model_id != "":
					payload["model"] = _last_model_id
				usage_updated.emit(payload)
		"message_stop":
			pass


func _handle_legacy_assistant(parsed: Dictionary) -> void:
	## Backward-compat path for CLIs that don't support --include-partial-messages.
	## Iterates ALL content blocks (not just [0]) and extracts text from each.
	var msg = parsed.get("message", {})
	if not msg is Dictionary:
		return
	var content = msg.get("content", [])
	if not (content is Array):
		return
	var snapshot_text := ""
	for block in content:
		if block is Dictionary and block.get("type") == "text":
			snapshot_text += block.get("text", "")
	# Each legacy assistant event is a snapshot of the latest block set — not
	# cumulative across blocks. Diff against the prior snapshot we've shown.
	if snapshot_text.length() > _stream_accumulated.length() \
	and snapshot_text.begins_with(_stream_accumulated):
		var new_chunk := snapshot_text.substr(_stream_accumulated.length())
		_stream_accumulated = snapshot_text
		_stream_text_accumulated += new_chunk
		stream_chunk.emit(new_chunk)
	elif not snapshot_text.is_empty() and snapshot_text != _stream_accumulated:
		# Different snapshot — a new block has started. Separate with \n\n and
		# emit the whole snapshot.
		stream_chunk.emit("\n\n")
		_stream_text_accumulated += "\n\n" + snapshot_text
		stream_chunk.emit(snapshot_text)
		_stream_accumulated = snapshot_text


func _handle_result_event(parsed: Dictionary) -> void:
	if parsed.get("is_error", false):
		_is_running = false
		error_occurred.emit(parsed.get("result", "Unknown error from Claude."))
		return

	# Emit a final, authoritative usage payload.
	var u = parsed.get("usage", {})
	var payload := {}
	if u is Dictionary:
		payload = _make_usage_payload(u, true)
	payload["total_cost_usd"] = parsed.get("total_cost_usd", 0.0)
	var model_usage = parsed.get("modelUsage", {})
	if model_usage is Dictionary and not model_usage.is_empty():
		# Pick the first (and usually only) model entry.
		for mid in model_usage.keys():
			var m_entry = model_usage[mid]
			if m_entry is Dictionary:
				payload["model"] = mid
				payload["context_window"] = m_entry.get("contextWindow", 0)
				payload["max_output_tokens"] = m_entry.get("maxOutputTokens", 0)
			break
	elif _last_model_id != "":
		payload["model"] = _last_model_id
	usage_updated.emit(payload)

	# Fallback: if neither streaming path produced any visible text, fall back
	# to the final `result` field so the user still sees something.
	if _stream_text_accumulated.is_empty():
		var result_text: String = parsed.get("result", "")
		if not result_text.is_empty():
			_stream_text_accumulated = result_text
			stream_chunk.emit(result_text)

	_is_running = false
	stream_finished.emit(parsed.get("session_id", ""))


func _make_usage_payload(u: Dictionary, is_final: bool) -> Dictionary:
	return {
		"input_tokens":                u.get("input_tokens", 0),
		"output_tokens":               u.get("output_tokens", 0),
		"cache_read_input_tokens":     u.get("cache_read_input_tokens", 0),
		"cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
		"is_final":                    is_final,
	}


func _reset_stream_state() -> void:
	_stream_accumulated = ""
	_stream_text_accumulated = ""
	_stream_read_pos = 0
	_stream_partial = ""
	_got_stream_event = false
	_current_block_type = ""
	_text_blocks_emitted = 0
	_last_model_id = ""


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
		if _stream_text_accumulated.is_empty() and _stream_accumulated.is_empty():
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
	model: String = "",
	effort: String = ""
) -> Array:
	var args: Array = prefix.duplicate()
	# --include-partial-messages gives us clean content_block_delta events,
	# which is the authoritative streaming format in Claude Code 2.x.
	args.append_array([
		"--print", "--output-format", "stream-json", "--verbose",
		"--include-partial-messages",
	])

	if model != "":
		args.append_array(["--model", model])

	if effort != "":
		args.append_array(["--effort", effort])

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
