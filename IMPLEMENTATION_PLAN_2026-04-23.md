# Implementation Plan — Claude CLI 2.1 Compatibility & UX Upgrade

**Date:** 2026-04-23
**Branch:** `claude/godot-claude-plugin-RGUfJ`
**Target CLI version:** Claude Code 2.1.119+
**Scope:** 5 items requested — fix truncation bug, add Opus 4.7, add effort setting, add subtle usage indicator, add Init/Compact buttons.

---

## 1. Root cause of the "cut-off / missing pieces" bug

The plugin's stream parser in `claude_runner.gd::_parse_ndjson_line` (lines 208–221) was written against an older CLI that emitted a single growing text block per response. The current CLI (2.1.x) emits an **`assistant` event per completed content block**, not a cumulative snapshot.

A single response now looks like this on the wire:

```
assistant  content=[{type:"thinking", ...}]          ← reasoning block (no text)
assistant  content=[{type:"text", text:"Let me check..."}]
assistant  content=[{type:"tool_use", ...}]          ← tool call
(tool_result)
assistant  content=[{type:"thinking", ...}]
assistant  content=[{type:"text", text:"Found it — here's the fix."}]
assistant  content=[{type:"tool_use", ...}]
(tool_result)
assistant  content=[{type:"text", text:"Done."}]
result     result="<final answer>", usage={...}
```

The current code does:

```gdscript
var block = content[0]                                # always [0]
if block.get("type") == "text":
    var full_text = block.get("text", "")
    if full_text.length() > _stream_accumulated.length():   # monotonic-grow assumption
        emit(full_text.substr(_stream_accumulated.length()))
        _stream_accumulated = full_text
```

**Three failure modes this produces — all of which match the user's report:**

1. **Short follow-up after a long one is silently dropped.** `"Done."` (5 chars) is shorter than the previous `_stream_accumulated`, so the guard skips it entirely.
2. **Middle of multi-block response is garbled.** When a new text block is shorter than the previous accumulated value, nothing is shown. When it is longer, the plugin emits `substr(old_len)` of the *new* block, which is a random suffix of an unrelated sentence.
3. **First visible text is prepended with leftovers.** Because `_stream_accumulated` is not reset between content blocks, the second text block's display offset is wrong.

**Fix:** switch the CLI invocation to `--include-partial-messages` and parse `stream_event` → `content_block_delta` → `text_delta` events, which are already designed exactly like Anthropic API deltas. Accumulate per-content-block, insert a blank line when a new text block starts after a tool/thinking block, and ignore thinking/signature deltas.

The `result` event still gives us the authoritative final text as a sanity check.

---

## 2. What's on the wire now (reference for the code changes)

Relevant event types in `--output-format stream-json --verbose --include-partial-messages`:

| Event | Purpose | Plugin action |
|---|---|---|
| `system/init` | Session init — includes `model`, `session_id`, `claude_code_version` | capture `session_id` early |
| `system/status status=requesting` | TTFB marker | swap thinking bubble color (optional) |
| `stream_event/message_start` | Message begins; first `usage.input_tokens` appears here | start/refresh usage display |
| `stream_event/content_block_start` (type=text) | New text block begins | if there is prior text, insert `\n\n` |
| `stream_event/content_block_delta` (text_delta) | Incremental token | append to bubble |
| `stream_event/content_block_delta` (thinking_delta) | Reasoning token | **ignore** (not surfaced) |
| `stream_event/content_block_delta` (signature_delta) | Crypto signature | ignore |
| `stream_event/content_block_start` (type=tool_use) | Tool call begins | render a subtle `[tool: Read]` chip (optional, see §6) |
| `stream_event/message_delta` | Final usage for this message | refresh usage display |
| `stream_event/message_stop` | Message finished | no-op |
| `assistant` | Snapshot of a finished block | **ignore** (we're using deltas now) |
| `user` | Tool results flowing back | ignore |
| `rate_limit_event` | Five-hour-window info | stash for usage bar tooltip |
| `result` | Final answer + full usage | confirm stream end, update usage |

---

## 3. Work items

### 3.1  Fix streaming parser (priority 1 — fixes the truncation bug)

**File:** `addons/claude_godot/claude_runner.gd`

- In `_build_send_args()`, add `--include-partial-messages` after `--verbose`.
- Rewrite `_parse_ndjson_line()` as a small state machine:
  - State: `_stream_text_accumulated` (for final history record), `_current_block_type` (text / thinking / tool_use / null), `_text_blocks_emitted` (int — used to decide whether to prefix a newline).
  - On `stream_event.message_start`: capture initial `usage` → `usage_updated.emit(...)`, reset block state.
  - On `stream_event.content_block_start`:
    - If `content_block.type == "text"` and `_text_blocks_emitted > 0`, emit `"\n\n"` to the bubble as a paragraph break.
    - Set `_current_block_type` to the new type.
  - On `stream_event.content_block_delta`:
    - `text_delta`: append `event.delta.text` to bubble **and** to `_stream_text_accumulated`.
    - `thinking_delta`: ignore.
    - `input_json_delta` (tool_use args): ignore (optional: stash for tool-chip tooltip).
  - On `stream_event.content_block_stop`: if `_current_block_type == "text"`, increment `_text_blocks_emitted`.
  - On `stream_event.message_delta`: emit `usage_updated` with the delta's usage.
  - On `result`: if `_stream_text_accumulated` is still empty (edge case — non-text-only response), use `parsed.result` as the fallback, otherwise ignore `result.result` (already streamed). Emit `stream_finished(session_id)` and a final `usage_updated` with the total.
- Keep the legacy `assistant`/`content_block_delta` branches as **silent fallback** for older CLI versions — only fire if we never saw a `stream_event` on this run (`_got_stream_event == false`). This preserves backward compatibility without double-writing.
- New signal: `signal usage_updated(usage: Dictionary)`.
- On startup, also capture the CLI version from the first `system/init` event (`claude_code_version`) and emit `signal cli_version_detected(version: String)` — used to show a quiet compatibility hint if the CLI is too old (`< 2.1.0`).

**Acceptance:** a long response that involves 3 tool calls shows all text paragraphs in order, no fragments, no duplicates. A short follow-up after a long one appears in full.

---

### 3.2  Opus 4.7 + CLI alias support

**File:** `addons/claude_godot/claude_panel.gd`

Update `_MODELS` to the current lineup, using **CLI aliases** (not pinned dated IDs) so the plugin auto-tracks Anthropic's "latest" selection going forward:

```gdscript
const _MODELS: Array = [
    ["Opus 4.7 (Most Capable)",    "opus"],
    ["Sonnet 4.6 (Default)",       "sonnet"],
    ["Haiku 4.5 (Fastest)",        "haiku"],
    ["Opus 4.6",                   "claude-opus-4-6"],     # pinned, for users who need stability
    ["Sonnet 4.5",                 "claude-sonnet-4-5"],
]
```

- Default remains `"sonnet"` (previously `"claude-sonnet-4-6"`).
- Migration: when loading settings, if `model` is a pinned ID whose alias is now current, leave it alone (user's choice). No forced rewrite.
- Tooltip on the model dropdown mentioning: *"Aliases (opus/sonnet/haiku) auto-track the latest model. Pick a pinned ID to lock to a specific version."*

**Acceptance:** selecting "Opus 4.7" sends `--model opus`; the stream-JSON init event reports `model=claude-opus-4-7-...`.

---

### 3.3  Effort level setting

**File:** `addons/claude_godot/claude_runner.gd`, `addons/claude_godot/claude_panel.gd`

CLI flag: `--effort <level>` where `level ∈ {low, medium, high, xhigh, max}`.

- Extend `ClaudeRunner.send()` and `ClaudeRunner.start_stream()` with a new `effort: String = ""` parameter; append `--effort <level>` in `_build_send_args()` when non-empty.
- In the settings dialog (`_open_settings_dialog`), add an OptionButton under the model row:

  ```
  Effort: [ Default | Low | Medium | High | Very High | Maximum ]
  ```

  Stored under key `"effort"` with default value `""` (= "don't pass the flag; use CLI default"). Tooltip explains: *"Higher effort = more reasoning tokens, slower, costlier. 'Default' uses the CLI's own default for the selected model."*
- Thread the value through `_send_message()` → `start_stream()` / `send()`.

**Acceptance:** selecting "High" causes `--effort high` to appear in the args; changing back to "Default" removes the flag.

---

### 3.4  Subtle usage visualization

**File:** `addons/claude_godot/claude_panel.gd`

**Design goal:** *subtle* — visible at a glance, not demanding attention, no modal popups.

Visual: a 3-pixel-tall `ProgressBar` embedded just above the status label (between chat area and input area). Color gradient based on ratio:

- `< 50%` → dim green `#3a6b3a`
- `50–80%` → muted amber `#a87a3a`
- `80–95%` → orange `#c87024`
- `> 95%` → red `#b03030`

Tooltip on hover shows the full breakdown:

```
Context: 47,283 / 200,000 tokens (23.6%)
  Input this turn: 9
  Cache read:     37,251
  Cache created:  11,032
  Output:         94
Last turn: 2.1s · $0.0179
Session total: $0.0817 · 3 turns
Rate limit: allowed (5h window) — resets in 43m
Model: claude-opus-4-7  ·  Effort: high
```

**Implementation:**
- Add `_usage_bar: ProgressBar` + `_usage_tooltip_data: Dictionary` fields.
- New method `_on_usage_updated(usage: Dictionary)` connected to `_runner.usage_updated`.
- Context window is per-model — harvest from the `result` event's `modelUsage.<id>.contextWindow` (200,000 for current models). Fall back to 200,000 if unknown.
- `used = input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (input side only — output doesn't consume the window).
- Session-level running totals (cost, turn count) kept in a small `_session_stats: Dictionary`; reset by **New Chat**.
- Rate limit info taken from `rate_limit_event` (optional — omit the line if event was never seen).
- The ProgressBar uses `show_percentage = false` and a custom `StyleBoxFlat` for the fill color; recolored whenever ratio changes.

**Acceptance:** after a few exchanges the bar visibly fills; hovering produces the full tooltip; starting a new chat resets the bar.

---

### 3.5  Init and Compact buttons

**File:** `addons/claude_godot/claude_panel.gd`

These are slash commands that Claude Code 2.1 accepts verbatim as the prompt — `/init` and `/compact` both work in `--print` mode (verified against the local CLI).

- Add two small buttons to the title bar, between `New` and `Clear`:
  - `Init` — tooltip: *"Run /init to generate or refresh CLAUDE.md for this project"*
  - `Compact` — tooltip: *"Run /compact to shrink the running conversation while preserving key context"*
- `Init` handler: sends `/init` as the prompt via the existing pipeline (just `_input_text.text = "/init"; _send_message()`), with `file_access` forced on for the duration of that one message (then restored) — `/init` writes a file, which requires `--add-dir`.
- `Compact` handler:
  - If `_session_id` is empty: show a short info message bubble ("Nothing to compact yet — start a conversation first.") and bail.
  - Otherwise send `/compact` via the normal pipeline. The result message is rendered as a system-style bubble (dim, italic) instead of a normal assistant bubble, so the UI reads like "session compacted" rather than "here's Claude's answer".
- Add a small `_add_system_message()` note before firing so the user sees what was triggered: e.g. `"Running /init..."` or `"Compacting session..."`.

**Edge cases:**
- `/init` without file access would fail — force `--add-dir` regardless of the `Files` toggle for this one command, and show a one-line explanation ("Init requires file access; temporarily enabled for this command.").
- `/compact` on an already-compacted session is harmless — no special handling needed.

**Acceptance:** clicking Init creates/updates `CLAUDE.md` in the project root; clicking Compact after a long chat returns a compacted session; the session id persists across both.

---

## 4. Files touched

| File | Changes |
|---|---|
| `addons/claude_godot/claude_runner.gd` | rewrite `_parse_ndjson_line`; add `--include-partial-messages`; add `effort` param; add `usage_updated` + `cli_version_detected` signals; keep legacy parser as silent fallback |
| `addons/claude_godot/claude_panel.gd` | new model list (Opus 4.7 via aliases); effort OptionButton in settings; `_usage_bar` + tooltip + session stats; Init/Compact title-bar buttons; `_on_usage_updated`; thread `effort` into `_send_message` |
| `addons/claude_godot/plugin.cfg` | bump version to `1.1.0` |
| `README.md` | short note on new features (optional — can defer) |

No changes to `context_builder.gd`, `plugin.gd`, `claude_context_menu.gd`, or `godot_doctor_bridge.gd`.

---

## 5. Risks & mitigations

- **`--include-partial-messages` unsupported on older CLIs.** Keep the legacy `assistant`-event branch as a fallback; detect via `cli_version_detected`. Unlikely in practice — the flag shipped in early 2.0.x.
- **`/init` overwrites an existing CLAUDE.md.** The CLI warns; we surface the warning as a system bubble. Don't add our own confirm dialog — would feel noisy.
- **Cost/usage numbers depend on Anthropic's pricing math.** We display what the CLI reports (`total_cost_usd`) without recomputation, so we inherit whatever accuracy it has.
- **Usage bar feeling "too ambient" and getting missed.** Mitigated by the color ramp (green → red) and tooltip — no other visual changes needed until the user asks for them.

---

## 6. Explicitly out of scope for this PR

- Tool-use inline chips (`[Read file.gd]`, `[Edit ...]`). Valuable but larger; would need a new bubble variant.
- `/clear`, `/context`, `/usage` as dedicated buttons (the user asked for Init + Compact specifically). They are still usable by just typing them in the input.
- Thinking-block display. The plugin currently hides reasoning entirely; revisiting that is a separate design question.
- Windows streaming (still falls back to the blocking `send()` path; the parser fix applies to that too, so Windows users also benefit from the truncation fix).

---

## 7. Order of operations when implementing

1. Parser rewrite + `--include-partial-messages` (unblocks everything else visually).
2. Model list update (one-line change, immediate win).
3. Effort OptionButton (additive, low risk).
4. `usage_updated` signal wiring + usage bar (depends on §1 for clean data).
5. Init / Compact buttons (cosmetic; depends on no other work).
6. Bump `plugin.cfg` version.
7. Manual test pass — see §8.

---

## 8. Manual test checklist (run in a scratch Godot 4 project)

- [ ] Long response with 3+ tool calls — every paragraph shows in order; no gibberish.
- [ ] Short follow-up after a long turn — the short one actually appears.
- [ ] Model dropdown: Opus 4.7 selected → `system/init` event shows `claude-opus-4-7-*`.
- [ ] Effort = High → `--effort high` in args (enable debug print or inspect with `ps`).
- [ ] Usage bar fills progressively; tooltip reads correctly; New Chat resets.
- [ ] Init button creates CLAUDE.md; Compact button returns a system-style summary bubble.
- [ ] Cancel button still aborts mid-stream without leaving a partial bubble.
- [ ] Windows blocking path: final answer still renders (the parser rewrite touches both paths).
