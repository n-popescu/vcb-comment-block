extends WindowDialog

# comment_edit_window.gd — the comment editor popup.
#
# Same kind of window as the game's Multiplayer / Board Size dialogs (a themed WindowDialog). It
# holds a multi-line text zone (the note-zone style used by the in-game assembly Notes) for the
# comment of one comment-block GROUP, keyed by the group's anchor cell.
#
# • Press Enter to save and close; Shift+Enter inserts a new line.
# • The text is streamed to the multiplayer peer LIVE as you type (like the Board Size field), so
#   both players see the comment being written; it's also stored on the block immediately.
# • If the peer edits the same comment while this window is open, the text updates here too.
#
# It talks only to CommentBlockSync at /root/CommentBlockSync; it never touches board state.

var _sync: Node = null
var _anchor := Vector2(-1, -1)
var _anchor_key := ""
var _text_edit: TextEdit
var _suppress_broadcast := false


func setup(sync_node: Node) -> void :
	_sync = sync_node
	if _sync != null and not _sync.is_connected("text_changed", self, "_on_remote_text"):
		var _e = _sync.connect("text_changed", self, "_on_remote_text")


func _ready() -> void :
	window_title = "Comment"
	resizable = true
	rect_min_size = Vector2(360, 240)

	var margin := MarginContainer.new()
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	margin.add_constant_override("margin_left", 12)
	margin.add_constant_override("margin_right", 12)
	margin.add_constant_override("margin_top", 12)
	margin.add_constant_override("margin_bottom", 12)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_constant_override("separation", 8)
	margin.add_child(vb)

	var hint := Label.new()
	hint.text = "Comment shown on hover. Enter = save, Shift+Enter = new line."
	hint.autowrap = true
	vb.add_child(hint)

	_text_edit = TextEdit.new()
	_text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_edit.wrap_enabled = true
	var _e = _text_edit.connect("text_changed", self, "_on_text_changed")
	vb.add_child(_text_edit)

	var row := HBoxContainer.new()
	row.add_constant_override("separation", 8)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.focus_mode = Control.FOCUS_NONE
	var _e2 = save_btn.connect("pressed", self, "_save_and_close")
	row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete comment"
	del_btn.focus_mode = Control.FOCUS_NONE
	var _e3 = del_btn.connect("pressed", self, "_delete_and_close")
	row.add_child(del_btn)
	vb.add_child(row)


# Open the editor for the group anchored at `anchor`.
func open_for(anchor: Vector2) -> void :
	_anchor = anchor
	if _sync != null and _sync.has_method("key_for"):
		_anchor_key = String(_sync.key_for(anchor))
	_set_text_silently(_current_text())
	popup_centered(Vector2(440, 300))
	_text_edit.grab_focus()


func _current_text() -> String:
	if _sync != null and _sync.has_method("get_text"):
		return String(_sync.get_text(_anchor))
	return ""


func _set_text_silently(text: String) -> void :
	if _text_edit == null:
		return
	_suppress_broadcast = true
	_text_edit.text = text
	if not _text_edit.has_focus():
		_text_edit.cursor_set_line(_text_edit.get_line_count())
	_suppress_broadcast = false


# Live-stream every keystroke to the block (and the peer).
func _on_text_changed() -> void :
	if _suppress_broadcast:
		return
	if _sync != null and _sync.has_method("set_text"):
		_sync.set_text(_anchor, _text_edit.text, true)


# The peer edited this same comment while our window is open — reflect it (don't yank the caret if
# we're mid-edit).
func _on_remote_text(anchor_key, text) -> void :
	if not visible:
		return
	if String(anchor_key) != _anchor_key:
		return
	_set_text_silently(String(text))


func _input(event: InputEvent) -> void :
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == KEY_ENTER or event.scancode == KEY_KP_ENTER:
			if event.shift:
				return  # Shift+Enter falls through to the TextEdit as a newline
			_save_and_close()
			get_tree().set_input_as_handled()


func _save_and_close() -> void :
	if _sync != null and _sync.has_method("set_text"):
		_sync.set_text(_anchor, _text_edit.text, true)
	hide()


func _delete_and_close() -> void :
	if _sync != null and _sync.has_method("remove_group"):
		_sync.remove_group(_anchor, true)
	hide()
