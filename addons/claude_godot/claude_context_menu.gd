## Adds "Ask Claude about this" to the Godot scene tree right-click menu.
## Requires Godot 4.3+ (EditorContextMenuPlugin API).
@tool
extends EditorContextMenuPlugin

## Set by plugin.gd immediately after instantiation.
var panel: Control


func _popup_menu(_paths: PackedStringArray) -> void:
	add_context_menu_item("Ask Claude about this", _on_ask_claude)


func _on_ask_claude(_paths: PackedStringArray) -> void:
	if is_instance_valid(panel) and panel.has_method("prefill_ask_about_selection"):
		panel.prefill_ask_about_selection()
