extends Node2D

# comment_block_overlay.gd — the on-board visual + interaction for comment blocks.
#
# Added under Main/World (sibling of CursorBoard) so it shares the board's pixel coordinate space
# and pans/zooms with the camera, exactly like the brush cursor. It:
#   • draws every placed comment block (from CommentBlockSync);
#   • shows a comment as a tooltip that FOLLOWS the mouse (down-right) with a stock-style
#     fade in/out (a Tween on modulate, like the game's own UI) whenever the pointer is over a
#     block — in edit mode AND during simulation (view-only);
#   • in "comment mode" (our toolbar button), routes board clicks to place a block (empty cell),
#     open the editor popup (existing block, left click), or delete a block (right click).
#
# Comment mode suppresses drawing by requesting the editor tool NONE, so the normal tools don't
# paint while you place/edit comments; picking any real tool (or entering simulation) leaves
# comment mode automatically.

const BLOCK_FILL := Color(0.882, 0.745, 0.514, 0.45)   # warm, semi-transparent (placeholder)
const BLOCK_EDGE := Color(0.882, 0.745, 0.514, 0.95)
const BLOCK_GLYPH := Color(0.15, 0.12, 0.07, 0.9)

var _sync: Node = null
var _editor: Node = null
var _window: Node = null
var _button = null

var _cell := 8
var _comment_mode := false
var _is_world_frame := false
var _prev_tool := -1

# Tooltip (screen-space, on its own CanvasLayer so it ignores the board camera transform).
var _tip_layer: CanvasLayer
var _tip_panel: PanelContainer
var _tip_label: Label
var _tip_tween: Tween
var _tip_shown := false


# Called by mod_main before this node is added to the tree, so refs exist when _ready runs.
func setup(sync: Node, editor: Node, window: Node) -> void :
	_sync = sync
	_editor = editor
	_window = window


func set_button(button) -> void :
	_button = button


func _ready() -> void :
	z_index = 20
	if _sync != null:
		_cell = int(_sync.get_cell_size())
		_sync.connect("blocks_changed", self, "_on_blocks_changed")
	E.follow_events(self, [
		E.mi_mouse_input_on_board,
		E.ui_context_change,
	])
	L_connect(E, "ed_tool_change_emitted", "_on_tool_change")
	L_connect(E, "mi_mode_change_requested", "_on_mi_mode_change")
	_build_tooltip()
	set_process(true)


# Small connect helper (mirrors the game's `L.sig = ... connect(...)` idiom without needing L).
func L_connect(obj: Object, sig: String, method: String) -> void :
	if not obj.is_connected(sig, self, method):
		var _e = obj.connect(sig, self, method)


func _build_tooltip() -> void :
	_tip_layer = CanvasLayer.new()
	_tip_layer.layer = 130
	add_child(_tip_layer)
	_tip_panel = PanelContainer.new()
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.modulate = Color(1, 1, 1, 0)
	_tip_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.11, 0.96)
	sb.set_border_width_all(1)
	sb.border_color = BLOCK_EDGE
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	_tip_panel.add_stylebox_override("panel", sb)
	_tip_layer.add_child(_tip_panel)
	_tip_label = Label.new()
	_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_label.add_color_override("font_color", Color(0.92, 0.93, 0.95))
	_tip_panel.add_child(_tip_label)
	_tip_tween = Tween.new()
	add_child(_tip_tween)
	var _e = _tip_tween.connect("tween_all_completed", self, "_on_tip_tween_done")


# --- drawing ----------------------------------------------------------------------------------
func _on_blocks_changed() -> void :
	update()


func _draw() -> void :
	if _sync == null:
		return
	var s := float(_cell)
	for cell in _sync.get_all_cells():
		var r := Rect2(cell.x * s, cell.y * s, s, s)
		draw_rect(r, BLOCK_FILL, true)
		draw_rect(r, BLOCK_EDGE, false, 1.0)
	# A small "quote" glyph on each group's anchor cell so a block reads as a comment marker.
	for cell in _sync.get_all_cells():
		if _sync.anchor_of(cell) == cell:
			var o := Vector2(cell.x * s, cell.y * s)
			var d := s * 0.22
			draw_rect(Rect2(o.x + s * 0.28, o.y + s * 0.3, d, d), BLOCK_GLYPH, true)
			draw_rect(Rect2(o.x + s * 0.55, o.y + s * 0.3, d, d), BLOCK_GLYPH, true)


# --- hover tooltip ----------------------------------------------------------------------------
func _process(_delta: float) -> void :
	if _sync == null:
		return
	var want := false
	var text := ""
	if _is_world_frame:
		var board_pos := get_global_mouse_position()
		if C.CIRCUIT.RECT.has_point(board_pos):
			var cell := _sync.cell_of(board_pos)
			if _sync.has_block(cell):
				want = true
				text = _sync.get_text(cell)
				if text == "":
					text = "(empty comment — click to add text)"
	if want:
		_tip_label.text = text
		# The PanelContainer auto-fits the label; follow the mouse, offset lower-right so the
		# pointer doesn't cover the text.
		_tip_panel.rect_position = get_viewport().get_mouse_position() + Vector2(18, 20)
		_show_tooltip()
	else:
		_hide_tooltip()


func _show_tooltip() -> void :
	if _tip_shown:
		return
	_tip_shown = true
	_tip_panel.visible = true
	_fade_tooltip(1.0)


func _hide_tooltip() -> void :
	if not _tip_shown:
		return
	_tip_shown = false
	_fade_tooltip(0.0)


func _fade_tooltip(a: float) -> void :
	var _d = _tip_tween.remove_all()
	_d = _tip_tween.interpolate_property(_tip_panel, "modulate", null,
			Color(1, 1, 1, a), 0.12, Tween.TRANS_SINE, Tween.EASE_IN_OUT)
	_d = _tip_tween.start()


func _on_tip_tween_done() -> void :
	if not _tip_shown:
		_tip_panel.visible = false


# --- comment mode -----------------------------------------------------------------------------
func _on_comment_button_toggled(pressed: bool) -> void :
	if pressed:
		enter_comment_mode()
	else:
		exit_comment_mode(true)


func enter_comment_mode() -> void :
	if _comment_mode:
		return
	if _editor != null and not bool(_editor.get("is_in_editor")):
		# Can't place comments while simulating; bounce the button back off.
		_set_button_pressed(false)
		return
	if _editor != null:
		_prev_tool = int(_editor.get("editor_tool"))
	_comment_mode = true
	# Suppress the normal drawing tools while placing/editing comments.
	E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.NONE)


func exit_comment_mode(restore_tool: bool) -> void :
	if not _comment_mode:
		return
	_comment_mode = false
	if restore_tool:
		var t := _prev_tool
		if t < 0 or t == Editor.TOOL.NONE or t == Editor.TOOL.SIMULATOR:
			t = Editor.TOOL.ARRAY
		E.emit_signal("ed_tool_change_emitted", true, t)


# Any real tool becoming active (toolbar pick, or entering simulation) leaves comment mode.
func _on_tool_change(is_request: bool, new_tool: int) -> void :
	if is_request:
		return
	if _comment_mode and new_tool != Editor.TOOL.NONE:
		_comment_mode = false
		_set_button_pressed(false)


func _on_mi_mode_change(is_simulation_requested: bool) -> void :
	if _button != null:
		_button.disabled = is_simulation_requested
	if is_simulation_requested and _comment_mode:
		_comment_mode = false
		_set_button_pressed(false)


func _set_button_pressed(value: bool) -> void :
	if _button == null:
		return
	_button.set_block_signals(true)
	_button.pressed = value
	_button.set_block_signals(false)


# --- board input (place / edit / delete) ------------------------------------------------------
func _ev_ui_context_change(_mode: int, _args: Dictionary) -> void :
	var p_stable_context: int = _args[E.ui_context_change.p_stable_context]
	_is_world_frame = p_stable_context == C.CONTEXT.WORLD_FRAME


func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	if not _comment_mode or _sync == null:
		return
	if _editor != null and not bool(_editor.get("is_in_editor")):
		return
	var p_position: Vector2 = _args[E.mi_mouse_input_on_board.p_position]
	var p_is_just_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_just_pressed]
	var p_is_left_click: bool = _args[E.mi_mouse_input_on_board.p_is_left_click]
	if not p_is_just_pressed:
		return
	if not C.CIRCUIT.RECT.has_point(p_position):
		return
	var cell := _sync.cell_of(p_position)
	if p_is_left_click:
		if _sync.has_block(cell):
			_open_editor(cell)
		else:
			_sync.place(cell, true)
	else:
		# Right click removes the block under the cursor (re-groups the rest).
		if _sync.has_block(cell):
			_sync.remove(cell, true)


func _open_editor(cell: Vector2) -> void :
	if _window == null:
		return
	var anchor: Vector2 = _sync.anchor_of(cell)
	if anchor.x < 0:
		return
	if _window.has_method("open_for"):
		_window.open_for(anchor)
