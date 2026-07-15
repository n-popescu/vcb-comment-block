extends Node2D

# comment_block_overlay.gd — the on-board visual + interaction for comment blocks.
#
# Added under Main/World (sibling of CursorBoard) so it shares the board's pixel coordinate space
# and pans/zooms with the camera, exactly like the brush cursor. It:
#   • draws every placed comment block (from CommentBlockSync);
#   • shows a comment as a tooltip that FOLLOWS the mouse (down-right) with a stock-style fade
#     in/out (a Tween on modulate, like the game's own UI) whenever the pointer is over a block —
#     in edit mode AND during simulation (view-only);
#   • when the Comment "ink" is the selected ink, DRAWS comment blocks with the mouse just like a
#     trace: left click / left drag places blocks; right click / right drag erases; and a plain
#     left click on an existing block opens its text editor.
#
# The comment ink is a real member of the ink ButtonGroup (added to the palette's "Annotation" row
# and to the Q/A quick menu). Selecting it deselects the current ink; picking any other ink (or a
# tool, or starting a simulation) leaves comment drawing again. While the comment ink is active the
# editor tool is held at NONE so the normal tools don't paint over the board — the mod places
# comment blocks itself.

# Comment block look — a warm translucent note colour that no vanilla ink uses (kept in sync with
# comment_ink_button.gd's COMMENT_ACCENT and the C.PALETTE["COMMENT"] entry mod_main registers).
const BLOCK_FILL := Color(0.882, 0.745, 0.514, 0.45)
const BLOCK_EDGE := Color(0.882, 0.745, 0.514, 0.95)
const BLOCK_GLYPH := Color(0.15, 0.12, 0.07, 0.9)

# The comment ink's "type id" — matches the entry mod_main registers in C.PALETTE and the
# indexed_color_id the comment buttons announce. When this becomes the active ink, we draw comments.
const COMMENT_ID := "COMMENT"

var _sync: Node = null
var _editor: Node = null
var _window: Node = null
var _buttons := []   # every comment-ink button (palette + quick-menu), kept selected-in-sync

var _cell := 8
var _active := false          # the comment ink is the selected ink → we're drawing comments
var _is_world_frame := false
var _prev_tool := -1
var _prev_ink_id := ""

# Drag state (so a held drag paints / erases blocks like a trace).
var _drag_place := false
var _drag_erase := false

# Tooltip (screen-space, on its own CanvasLayer so it ignores the board camera transform).
var _tip_layer: CanvasLayer
var _tip_panel: PanelContainer
var _tip_label: Label
var _tip_tween: Tween
var _tip_shown := false


# Called by mod_main before this node is added to the tree, so refs exist when _ready runs.
func setup(sync_node: Node, editor: Node, window: Node) -> void :
	_sync = sync_node
	_editor = editor
	_window = window


# Register a comment-ink button (the palette entry, the quick-menu entry) so the overlay can
# disable it during simulation. Selection is NOT driven from here: the comment buttons announce the
# "COMMENT" ink like every native ink, so the overlay enters/leaves comment drawing from the
# authoritative `ed_indexed_color_change` event (see `_ev_ed_indexed_color_change`).
func register_button(button) -> void :
	if button == null or button in _buttons:
		return
	_buttons.append(button)


func _ready() -> void :
	z_index = 20
	if _sync != null:
		_cell = int(_sync.get_cell_size())
		_sync.connect("blocks_changed", self, "_on_blocks_changed")
	# Seed the "previous ink" with whatever ink is active now, so leaving comment drawing (via a
	# tool pick or simulation) can always hand the highlight back to a real ink — even if COMMENT
	# is the very first ink the user selects after the game loads.
	if _editor != null:
		var cur := String(_editor.get("indexed_color_id"))
		if cur != "" and cur != COMMENT_ID:
			_prev_ink_id = cur
	E.follow_events(self, [
		E.mi_mouse_input_on_board,
		E.ui_context_change,
		E.ed_indexed_color_change,
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
			var cell: Vector2 = _sync.cell_of(board_pos)
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


# --- selecting / deselecting the comment ink --------------------------------------------------
# The selected ink changed. This is the authoritative hook: the comment buttons announce the
# "COMMENT" ink exactly like the native ink buttons announce theirs, so we enter comment drawing
# when COMMENT becomes the active ink and leave the moment any other ink is picked. We also track
# the last real ink here, to hand the highlight back when we leave for a reason other than an ink
# pick (a tool pick, or simulation start).
func _ev_ed_indexed_color_change(_mode: int, _args: Dictionary) -> void :
	var id := String(_args[E.ed_indexed_color_change.p_indexed_color_id])
	if id == COMMENT_ID:
		_enter()
	else:
		_prev_ink_id = id
		if _active:
			# Another ink was picked — it's already active and highlighted, so just stop drawing
			# comments and hand the editor tool back to what it was.
			_leave(true, false)


func _enter() -> void :
	if _active:
		return
	if _editor != null and not bool(_editor.get("is_in_editor")):
		# Can't place comments while simulating.
		return
	if _editor != null:
		_prev_tool = int(_editor.get("editor_tool"))
	_active = true
	_drag_place = false
	_drag_erase = false
	# Hold the normal drawing tools at NONE so nothing is painted while we place comment blocks
	# ourselves (the editor's mouse handler has no branch for NONE, so the board is left untouched).
	E.emit_signal("ed_tool_change_emitted", true, Editor.TOOL.NONE)


# Stop drawing comments. `restore_tool` puts the editor tool back to what it was before (used when
# an ink was picked — inks don't change the tool, but we clobbered it to NONE on enter).
# `repick_ink` re-selects the previously active ink so the ink grid isn't left with nothing
# highlighted (used when the exit wasn't itself an ink pick — a tool pick, or simulation start).
func _leave(restore_tool: bool, repick_ink: bool) -> void :
	if not _active:
		return
	_active = false
	_drag_place = false
	_drag_erase = false
	if restore_tool:
		var t := _prev_tool
		if t < 0 or t == Editor.TOOL.NONE or t == Editor.TOOL.SIMULATOR:
			t = Editor.TOOL.ARRAY
		E.emit_signal("ed_tool_change_emitted", true, t)
	if repick_ink and _prev_ink_id != "" and _prev_ink_id != COMMENT_ID:
		E.echo(E.ed_indexed_color_pick, {
			E.ed_indexed_color_pick.p_indexed_color_id: _prev_ink_id, })


# A real tool was picked while drawing comments — keep the tool the user chose, but hand the ink
# highlight back to the previous ink.
func _on_tool_change(is_request: bool, new_tool: int) -> void :
	if is_request:
		return
	if not _active:
		return
	if new_tool == Editor.TOOL.NONE:
		return
	_leave(false, true)


func _on_mi_mode_change(is_simulation_requested: bool) -> void :
	for b in _buttons:
		if is_instance_valid(b):
			b.disabled = is_simulation_requested
	if is_simulation_requested and _active:
		_leave(false, true)


# --- board input (place / edit / delete, click AND drag) --------------------------------------
func _ev_ui_context_change(_mode: int, _args: Dictionary) -> void :
	var p_stable_context: int = _args[E.ui_context_change.p_stable_context]
	_is_world_frame = p_stable_context == C.CONTEXT.WORLD_FRAME


func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	if not _active or _sync == null:
		return
	if _editor != null and not bool(_editor.get("is_in_editor")):
		return
	var p_position: Vector2 = _args[E.mi_mouse_input_on_board.p_position]
	var p_is_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_pressed]
	var p_is_just_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_just_pressed]
	var p_is_just_released: bool = _args[E.mi_mouse_input_on_board.p_is_just_released]
	var p_is_left_click: bool = _args[E.mi_mouse_input_on_board.p_is_left_click]
	if p_is_just_released:
		_drag_place = false
		_drag_erase = false
		return
	if not C.CIRCUIT.RECT.has_point(p_position):
		return
	var cell: Vector2 = _sync.cell_of(p_position)
	if p_is_left_click:
		if p_is_just_pressed:
			if _sync.has_block(cell):
				# A plain click on an existing block opens its editor (don't start a paint-drag).
				_drag_place = false
				_open_editor(cell)
			else:
				_sync.place(cell, true)
				_drag_place = true
		elif p_is_pressed and _drag_place:
			if not _sync.has_block(cell):
				_sync.place(cell, true)
	else:
		# Right button erases (click + drag), like erasing a trace.
		if p_is_just_pressed:
			_drag_erase = true
		if _drag_erase and _sync.has_block(cell):
			_sync.remove(cell, true)


func _open_editor(cell: Vector2) -> void :
	if _window == null:
		return
	var anchor: Vector2 = _sync.anchor_of(cell)
	if anchor.x < 0:
		return
	if _window.has_method("open_for"):
		_window.open_for(anchor)
