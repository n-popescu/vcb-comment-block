extends Node2D

# comment_block_overlay.gd — the on-board visual + interaction for comment blocks.
#
# Added under Main/World (sibling of CursorBoard) so it shares the board's pixel coordinate space
# and pans/zooms with the camera, exactly like the brush cursor. It:
#   • marks every comment zone with the "T" text glyph at the zone's top-left cell (always shown,
#     in every mode) so a comment reads as an annotation marker without hiding the board;
#   • shows the warm-orange zone overlay ONLY when it's useful: for every zone while the comment
#     ink is selected (so you can see where comment zones are while placing them), and — with any
#     other tool/ink — only on the single zone the mouse is hovering, fading in/out;
#   • shows a comment as a tooltip that FOLLOWS the mouse (down-right) with a stock-style fade
#     in/out (a Tween on modulate, like the game's own UI) whenever the pointer is over a block —
#     in edit mode AND during simulation (view-only);
#   • when the Comment "ink" is the selected ink, DRAWS comment blocks with the mouse just like a
#     trace: left click / left drag places blocks; right click / right drag erases; and a plain
#     left click on an existing block opens its text editor.
#
# The comment ink is a real member of the ink ButtonGroup (added to the palette's "Annotation" row
# and to the Q/A quick menu). Selecting it deselects the current ink; picking any other ink (or a
# tool, or starting a simulation) leaves comment drawing again. While the comment ink is active we
# hold the EDITOR's tool at NONE — but set directly on the editor, WITHOUT emitting a tool-change
# event — so nothing is painted locally (the editor's board handler has no branch for NONE) yet the
# editor toolbar / side panel stay exactly as they were (they only react to the tool-change event,
# so they keep showing the previous tool while the comment ink is highlighted, like any other ink).
# Remote multiplayer drawing is unaffected: it applies with the tool carried in its own payload.

# Comment block look — a warm translucent note colour that no vanilla ink uses (kept in sync with
# comment_ink_button.gd's COMMENT_ACCENT and the C.PALETTE["COMMENT"] entry mod_main registers).
const BLOCK_FILL := Color(0.882, 0.745, 0.514, 0.45)
const BLOCK_EDGE := Color(0.882, 0.745, 0.514, 0.95)
const BLOCK_GLYPH := Color(0.15, 0.12, 0.07, 0.9)

# The zone marker: the game's white "T" text glyph, tinted the comment accent so it reads as a
# comment marker on the dark board. Drawn at each zone's top-left (anchor) cell, always visible.
const T_ICON_PATH := "res://assets/icons/18px/text_symbol.png"
const T_TINT := Color(0.882, 0.745, 0.514, 1.0)

# Fade speed for the orange zone overlay (units of alpha per second → ~0.12 s to full, matching the
# tooltip fade and the stock UI idiom).
const FADE_SPEED := 8.0

# The comment ink's "type id" — matches the entry mod_main registers in C.PALETTE and the
# indexed_color_id the comment buttons announce. When this becomes the active ink, we draw comments.
const COMMENT_ID := "COMMENT"

var _sync: Node = null
var _editor: Node = null
var _window: Node = null
var _mp: Node = null   # multiplayer autoload (optional) — for author name + colour
var _buttons := []   # every comment-ink button (palette + quick-menu), kept selected-in-sync

var _cell := 8
var _active := false          # the comment ink is the selected ink → we're drawing comments
var _is_world_frame := false
var _prev_tool := -1
var _prev_ink_id := ""

# Orange zone overlay state. `_all_alpha` fades in while the comment ink is active (all zones show);
# `_hover_alpha` fades in for the single hovered zone the rest of the time. `_hover_cells` is the
# cell set of the currently hovered zone (keyed like CommentBlockSync), `_hover_anchor` its anchor.
var _tex_t: Texture = null
var _all_alpha := 0.0
var _hover_alpha := 0.0
var _hover_anchor := Vector2(-1, -1)
var _hover_cells := {}

# Drag state (so a held drag paints / erases blocks like a trace).
var _drag_place := false
var _drag_erase := false

# Brush size in board pixels for the next placement — 8x8 (default) or 4x4, chosen from the comment
# ink button's right-click menu. Placement stamps a square footprint of this size at the cursor.
var _brush_px := 8
# Placement preview: the top-left cell of where the next block would land while the comment ink is
# active (or (-1,-1) when there's nothing to preview).
var _preview_origin := Vector2(-1, -1)
# Last comment-mode presence we broadcast to peers (resent only on change), so the other player can
# see our placement preview in our multiplayer colour.
var _last_presence_active := false
var _last_presence_brush := 8
var _last_presence_cell := Vector2(-1, -1)

# Cached group geometry (per group: its cells, colour, and the centered "T" rect), rebuilt from the
# data model only when blocks change AND we're not mid-drag. A place/erase DRAG therefore no longer
# recomputes every group's bounds and T position on each placed cell — that per-cell recompute was
# the "lag while drawing/dragging". Geometry is refreshed once when the drag is released.
var _geom := []
var _geom_dirty := true

# What comment visuals are shown this frame: 0 = nothing, 1 = every zone (fill + T), 2 = only the
# hovered zone (fade in on hover). In EDIT mode everything shows with the comment ink OR the
# selection tool (so you can see/grab zones to move them), and NOTHING with a drawing tool (so you
# can draw circuit UNDER comments); in SIMULATION the hovered zone shows only when the "Show
# comments" checkbox is ticked.
var _reveal := 0

# The sim-mode "Show comments" checkbox (built by mod_main into the simulation side panel). When it
# is off, comment visuals + the hover tooltip are suppressed during simulation.
var _show_cb = null

# Zone-move drag (selection tool): grab a comment zone and drag the WHOLE group (its text rides
# along). The group stays put until the mouse is released; a tentative ghost shows where it would
# land (green = ok, red = blocked because it would overlap/touch another comment or leave the
# board). While moving, the editor tool is pinned to NONE so the selection tool doesn't also act,
# and restored on release. On an invalid drop the group simply stays where it was.
var _move_active := false
var _move_member := Vector2(-1, -1)
var _move_press_cell := Vector2(-1, -1)
var _move_delta := Vector2(0, 0)
var _move_cells := []
var _move_restore_tool := -1

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


# The sim-mode "Show comments" checkbox (mod_main builds it into the simulation side panel and hands
# it here). Read live in _process; when it's off, comment visuals are hidden during simulation.
func set_show_checkbox(cb) -> void :
	_show_cb = cb


func _show_comments_enabled() -> bool:
	if _show_cb != null and is_instance_valid(_show_cb) and _show_cb.has_method("public_get_pressed"):
		return bool(_show_cb.public_get_pressed())
	return false


# Set the placement brush size (board pixels: 4 or 8), from the comment ink button's right-click
# size menu. Both comment buttons drive this single shared value.
func set_brush_size(px: int) -> void :
	if px != 4 and px != 8:
		return
	_brush_px = px
	update()


func get_brush_size() -> int:
	return _brush_px


# How many grid cells a side of the current brush spans (8px brush = 2 cells on the 4px grid).
func _footprint_side() -> int:
	var n: int = _brush_px / _cell
	if n < 1:
		n = 1
	return n


# The cells a brush of the current size covers when anchored (top-left) at `origin`.
func _footprint_cells(origin: Vector2) -> Array:
	var n: int = _footprint_side()
	var out := []
	for dy in range(n):
		for dx in range(n):
			out.append(Vector2(origin.x + dx, origin.y + dy))
	return out


# The multiplayer autoload, if present (may be absent — this mod works solo).
func _get_mp() -> Node:
	if _mp == null or not is_instance_valid(_mp):
		_mp = get_tree().root.get_node_or_null("MP")
	return _mp


# A comment group's colour: its author's multiplayer hover colour, or the default warm tan when
# solo / the author is unknown (matches BLOCK_FILL/BLOCK_EDGE/T_TINT).
func _group_color(grp: Array) -> Color:
	var author: int = 0
	if _sync != null and _sync.has_method("get_author"):
		author = int(_sync.get_author(grp[0]))
	if author != 0:
		var mp := _get_mp()
		if mp != null and mp.has_method("get_player_color"):
			return mp.get_player_color(author)
	return Color(0.882, 0.745, 0.514)


func _ready() -> void :
	z_index = 20
	_tex_t = _load_t_texture()
	if _sync != null:
		_cell = int(_sync.get_cell_size())
		_sync.connect("blocks_changed", self, "_on_blocks_changed")
		if _sync.has_signal("presence_changed") and not _sync.is_connected("presence_changed", self, "_on_blocks_changed"):
			var _ep = _sync.connect("presence_changed", self, "_on_blocks_changed")
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
	# We watch raw input to start a zone-move BEFORE cursor_board echoes the board event, so we can
	# pin the tool to NONE and stop the selection tool from also acting on that press (see _input).
	set_process_input(true)


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
	# Mid place/erase drag: DON'T rebuild the group geometry per placed cell (that recompute was the
	# lag). The cheap draw path shows the raw cells; the geometry (and the T positions) is rebuilt
	# once when the drag is released. Otherwise (remote edit, move, undo, load…) refresh normally.
	if not (_drag_place or _drag_erase):
		_geom_dirty = true
	update()


# Recompute each group's cell list, colour and centered "T" rect from the data model. Done lazily
# (only when _geom_dirty and not mid-drag), so it runs on discrete changes / drag-release, not on
# every placed cell.
func _rebuild_geom() -> void :
	_geom = []
	if _sync == null:
		_geom_dirty = false
		return
	var s := float(_cell)
	var tsz: float = float(_cell) * 2.0 * 0.8
	for grp in _sync.get_groups():
		if grp.empty():
			continue
		var col := _group_color(grp)
		var minx: float = grp[0].x
		var miny: float = grp[0].y
		var maxx: float = grp[0].x
		var maxy: float = grp[0].y
		for c in grp:
			minx = min(minx, c.x)
			miny = min(miny, c.y)
			maxx = max(maxx, c.x)
			maxy = max(maxy, c.y)
		var bw: float = (maxx - minx + 1.0) * s
		var bh: float = (maxy - miny + 1.0) * s
		var tx: float = minx * s + (bw - tsz) * 0.5
		var ty: float = miny * s + (bh - tsz) * 0.5
		var anchor: Vector2 = _sync.anchor_of(grp[0])
		_geom.append({
			"cells": grp,
			"color": col,
			"trect": Rect2(tx, ty, tsz, tsz),
			"anchor_key": String(_sync.key_for(anchor)),
		})
	_geom_dirty = false


# Load the stock white "T" glyph used as the comment-zone marker (null if it's somehow missing —
# _draw then falls back to the little quote glyph).
func _load_t_texture() -> Texture:
	if ResourceLoader.exists(T_ICON_PATH):
		var t = load(T_ICON_PATH)
		if t is Texture:
			return t
	return null


func _draw() -> void :
	if _sync == null:
		return
	var s := float(_cell)
	# Nothing is shown with a drawing tool (edit) or with the sim toggle off — so you can draw
	# circuit under comments, and the sim board stays clean until you ask to see comments.
	if _reveal == 0:
		return
	# Mid place/erase drag: cheap path. Draw every current cell as a plain fill (no per-cell group
	# flood-fill), plus the CACHED (pre-drag) "T" markers so existing markers don't jump around while
	# you paint. Group geometry / T positions are recomputed once on release (see _on_blocks_changed).
	if _drag_place or _drag_erase:
		var a0 := _all_alpha
		if a0 > 0.003:
			var tan_col := Color(0.882, 0.745, 0.514)
			var fill := tan_col
			fill.a = BLOCK_FILL.a * a0
			var edge := tan_col
			edge.a = BLOCK_EDGE.a * a0
			for c in _sync.get_all_cells():
				draw_rect(Rect2(c.x * s, c.y * s, s, s), fill, true)
				draw_rect(Rect2(c.x * s, c.y * s, s, s), edge, false, 1.0)
		for gm in _geom:
			var tcol0: Color = gm["color"]
			tcol0.a = 1.0
			_draw_t(gm["trect"], tcol0)
		_draw_place_preview(s)
		return
	if _geom_dirty:
		_rebuild_geom()
	var hover_key := ""
	if _hover_anchor.x >= 0:
		hover_key = String(_sync.key_for(_hover_anchor))
	# Per group: faded fill/edge where visible + the fixed-size centered "T" marker.
	for gm in _geom:
		var col: Color = gm["color"]
		for c in gm["cells"]:
			var a := 0.0
			if _reveal == 1:
				a = _all_alpha
			if _hover_cells.has(_sync.key_for(c)):
				a = max(a, _hover_alpha)
			if a > 0.003:
				var fill := col
				fill.a = BLOCK_FILL.a * a
				var edge := col
				edge.a = BLOCK_EDGE.a * a
				draw_rect(Rect2(c.x * s, c.y * s, s, s), fill, true)
				draw_rect(Rect2(c.x * s, c.y * s, s, s), edge, false, 1.0)
		# T marker: every zone when reveal==1; only the hovered zone when reveal==2 (sim hover).
		var show_t: bool = _reveal == 1 or (_reveal == 2 and String(gm["anchor_key"]) == hover_key)
		if show_t:
			var tcol: Color = col
			tcol.a = 1.0
			_draw_t(gm["trect"], tcol)
	if _active:
		_draw_place_preview(s)
	if _reveal == 1:
		_draw_remote_presence(s)
		_draw_move_ghost(s)


# Draw the fixed-size "T" glyph (or the fallback quote glyph) into `rect`, tinted `col`.
func _draw_t(rect: Rect2, col: Color) -> void :
	if _tex_t != null:
		draw_texture_rect(_tex_t, rect, false, col)
	else:
		var d: float = rect.size.x * 0.35
		draw_rect(Rect2(rect.position.x + rect.size.x * 0.1, rect.position.y + rect.size.y * 0.15, d, d), BLOCK_GLYPH, true)
		draw_rect(Rect2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.15, d, d), BLOCK_GLYPH, true)


# Faint fill + outline of where the next block will land (only while the comment ink is active).
func _draw_place_preview(s: float) -> void :
	if not (_active and _preview_origin.x >= 0):
		return
	var pf := BLOCK_FILL
	pf.a = 0.30
	for pc in _footprint_cells(_preview_origin):
		draw_rect(Rect2(pc.x * s, pc.y * s, s, s), pf, true)
	var side := _footprint_side()
	draw_rect(Rect2(_preview_origin.x * s, _preview_origin.y * s, side * s, side * s), BLOCK_EDGE, false, 1.5)


# Remote peers' comment placement previews (multiplayer): each other player's footprint, drawn in
# THAT player's colour, so their comment-mode hover shows here instead of only the default cursor.
func _draw_remote_presence(s: float) -> void :
	if not _sync.has_method("get_remote_presence"):
		return
	var presence = _sync.get_remote_presence()
	if typeof(presence) != TYPE_DICTIONARY or presence.empty():
		return
	var mp := _get_mp()
	for pid in presence.keys():
		var info = presence[pid]
		if typeof(info) != TYPE_DICTIONARY:
			continue
		var rcell = info.get("cell", Vector2(-1, -1))
		if rcell.x < 0:
			continue
		var rbrush: int = int(info.get("brush", 8))
		var rn: int = rbrush / _cell
		if rn < 1:
			rn = 1
		var rcol := Color(0.882, 0.745, 0.514)
		if mp != null and mp.has_method("get_player_color"):
			rcol = mp.get_player_color(int(pid))
		var rfill := rcol
		rfill.a = 0.30
		for dy in range(rn):
			for dx in range(rn):
				draw_rect(Rect2((rcell.x + dx) * s, (rcell.y + dy) * s, s, s), rfill, true)
		var redge := rcol
		redge.a = 0.95
		draw_rect(Rect2(rcell.x * s, rcell.y * s, rn * s, rn * s), redge, false, 1.5)


# While a zone-move drag is in progress, draw the tentative destination footprint: green when the
# drop is allowed, red when it's blocked (overlaps/touches another comment, or leaves the board).
func _draw_move_ghost(s: float) -> void :
	if not _move_active:
		return
	if int(_move_delta.x) == 0 and int(_move_delta.y) == 0:
		return
	var ok: bool = _sync.can_move_group(_move_member, _move_delta)
	var col: Color = Color(0.42, 0.86, 0.45) if ok else Color(0.90, 0.35, 0.32)
	var fill := col
	fill.a = 0.28
	for c in _move_cells:
		var t: Vector2 = c + _move_delta
		draw_rect(Rect2(t.x * s, t.y * s, s, s), fill, true)
		draw_rect(Rect2(t.x * s, t.y * s, s, s), col, false, 1.5)


# --- hover tooltip + zone-overlay fade --------------------------------------------------------
func _process(delta: float) -> void :
	if _sync == null:
		return
	_update_reveal()
	# Safety net: if an in-progress move ever loses its release event, finish it once the left
	# button is up again (so the pinned editor tool is always restored).
	if _move_active and not Input.is_mouse_button_pressed(BUTTON_LEFT):
		_finish_move()
	# Which comment cell is the mouse over (if any)? Used for both the tooltip and, when NOT in
	# comment-drawing mode, the hover zone highlight. Skipped entirely when nothing is shown.
	var hovered_cell = null
	var text := ""
	var board_pos := Vector2(-1, -1)
	if _is_world_frame and _reveal != 0:
		board_pos = get_global_mouse_position()
		if C.CIRCUIT.RECT.has_point(board_pos):
			var cell: Vector2 = _sync.cell_of(board_pos)
			if _sync.has_block(cell):
				hovered_cell = cell
				text = _sync.get_text(cell)
				if text == "":
					text = "(empty comment — click to add text)"
	# Placement preview: while the comment ink is active, show where the next block would land.
	var new_preview := Vector2(-1, -1)
	if _active and _is_world_frame and C.CIRCUIT.RECT.has_point(board_pos):
		new_preview = _sync.cell_of(board_pos)
	if new_preview != _preview_origin:
		_preview_origin = new_preview
		update()
	# Broadcast our comment-mode presence (brush + hovered cell) so the peer can preview our
	# placement in our colour. Resent only when it changes (or when we enter/leave comment mode).
	var pres_active := _active and _preview_origin.x >= 0
	var pres_changed := pres_active != _last_presence_active
	if pres_active and (_preview_origin != _last_presence_cell or _brush_px != _last_presence_brush):
		pres_changed = true
	if pres_changed:
		_last_presence_active = pres_active
		_last_presence_cell = _preview_origin
		_last_presence_brush = _brush_px
		if _sync.has_method("broadcast_presence"):
			_sync.broadcast_presence(pres_active, _brush_px, _preview_origin)
	# Tooltip follows the mouse (offset lower-right so the pointer doesn't cover the text). In a
	# multiplayer session it's prefixed with the note author's name and its border is tinted the
	# author's colour; solo it stays the default warm tan.
	if hovered_cell != null:
		var display := text
		var border := BLOCK_EDGE
		var author: int = 0
		if _sync.has_method("get_author"):
			author = int(_sync.get_author(hovered_cell))
		if author != 0:
			var mp := _get_mp()
			if mp != null:
				if mp.has_method("get_player_name"):
					display = str(mp.get_player_name(author)) + ": " + text
				if mp.has_method("get_player_color"):
					border = mp.get_player_color(author)
		_tip_label.text = display
		_set_tip_border(border)
		_tip_panel.rect_position = get_viewport().get_mouse_position() + Vector2(18, 20)
		_show_tooltip()
	else:
		_hide_tooltip()
	# Hover zone highlight: only outside comment-drawing mode (in comment mode every zone already
	# shows). Recompute the hovered zone's cells only when the hovered zone changes.
	var new_anchor := Vector2(-1, -1)
	if hovered_cell != null and not _active:
		new_anchor = _sync.anchor_of(hovered_cell)
	if new_anchor != _hover_anchor:
		_hover_anchor = new_anchor
		_hover_cells = {}
		if new_anchor.x >= 0:
			for c in _sync.group_cells(new_anchor):
				_hover_cells[_sync.key_for(c)] = true
		update()
	# Fade the overlays toward their targets, redrawing while they move. reveal==1 shows every zone
	# (comment ink OR selection tool); the hovered zone gets an extra bump; reveal==2 (sim + toggle
	# on) shows only the hovered zone.
	var all_target := 0.0
	if _reveal == 1:
		all_target = 1.0
	var hover_target := 0.0
	if _reveal != 0 and not _hover_cells.empty():
		hover_target = 1.0
	var prev_all := _all_alpha
	var prev_hover := _hover_alpha
	_all_alpha = _approach(_all_alpha, all_target, delta)
	_hover_alpha = _approach(_hover_alpha, hover_target, delta)
	if abs(_all_alpha - prev_all) > 0.0001 or abs(_hover_alpha - prev_hover) > 0.0001:
		update()


# Decide what comment visuals to show this frame (see _reveal). EDIT: everything with the comment
# ink OR the selection tool (so zones are visible/grabbable), nothing with a drawing tool (draw
# under comments). SIM: the hovered zone only, and only when the "Show comments" checkbox is on.
func _update_reveal() -> void :
	var in_edit := true
	var cur_tool := -1
	if _editor != null:
		in_edit = bool(_editor.get("is_in_editor"))
		cur_tool = int(_editor.get("editor_tool"))
	var reveal := 0
	if in_edit:
		if _active or _move_active or cur_tool == Editor.TOOL.SELECTION:
			reveal = 1
	elif _show_comments_enabled():
		reveal = 2
	if reveal != _reveal:
		_reveal = reveal
		update()


# Move `cur` toward `target` at FADE_SPEED per second, clamping so it never overshoots.
func _approach(cur: float, target: float, delta: float) -> float:
	var step := FADE_SPEED * delta
	if cur < target:
		return min(cur + step, target)
	return max(cur - step, target)


func _set_tip_border(c: Color) -> void :
	if _tip_panel == null:
		return
	var sb = _tip_panel.get_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.border_color = c


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
	_active = true
	_drag_place = false
	_drag_erase = false
	# Suppress the editor's LOCAL board painting while the comment ink is active, but do it WITHOUT
	# emitting a tool-change event: we set editor_tool to NONE straight on the editor. The editor's
	# board handler has no branch for NONE (so nothing is painted here), while circuit_editor.gd /
	# footer.gd — which only listen to the tool-change EVENT — never hear about it and keep the
	# toolbar/side panel showing the previous tool with the comment ink highlighted. Remote drawing
	# in multiplayer still applies: it uses the editor tool carried in its own event payload.
	if _editor != null:
		_prev_tool = int(_editor.get("editor_tool"))
		_editor.set("editor_tool", Editor.TOOL.NONE)


# Stop drawing comments. `restore_tool` puts the editor tool back to what it was before entering
# (used for every exit EXCEPT a tool pick, where the picked tool must stay). `repick_ink`
# re-selects the previously active ink so the ink grid isn't left with nothing highlighted (used
# when the exit wasn't itself an ink pick — a tool pick, or simulation start).
func _leave(restore_tool: bool, repick_ink: bool) -> void :
	if not _active:
		return
	_active = false
	_drag_place = false
	_drag_erase = false
	if _editor != null:
		var t := _prev_tool
		if t == Editor.TOOL.NONE or t == Editor.TOOL.SIMULATOR or t < 0:
			t = Editor.TOOL.ARRAY
		# While the comment ink was active the editor tool was held at NONE, so anything that copied
		# editor_tool into last_tool (picking a tool, or starting a simulation) captured NONE.
		# Restore last_tool to the real previous tool so leaving a simulation — which re-applies
		# last_tool — doesn't blank the toolbar.
		_editor.set("last_tool", t)
		if restore_tool:
			_editor.set("editor_tool", t)
	if repick_ink and _prev_ink_id != "" and _prev_ink_id != COMMENT_ID:
		E.echo(E.ed_indexed_color_pick, {
			E.ed_indexed_color_pick.p_indexed_color_id: _prev_ink_id, })


# A real tool was picked while drawing comments — keep the tool the user chose, but hand the ink
# highlight back to the previous ink. NONE is our own pin (never emitted, but ignore defensively);
# SIMULATOR is the sim's own tool switch and is handled by `_on_mi_mode_change` (which restores the
# editor tool) — reacting to it here would leave with the wrong restore semantics and blank the
# toolbar after the sim.
func _on_tool_change(is_request: bool, new_tool: int) -> void :
	if is_request:
		return
	# A real tool change while dragging a zone abandons the move (the event already set the new tool,
	# so don't restore editor_tool ourselves — just drop the pending move, leaving the group put).
	if _move_active and new_tool != Editor.TOOL.NONE:
		_abandon_move()
	if not _active:
		return
	if new_tool == Editor.TOOL.NONE or new_tool == Editor.TOOL.SIMULATOR:
		return
	_leave(false, true)


func _on_mi_mode_change(is_simulation_requested: bool) -> void :
	for b in _buttons:
		if is_instance_valid(b):
			b.disabled = is_simulation_requested
	# Entering a simulation abandons any in-progress zone move.
	if is_simulation_requested and _move_active:
		_abandon_move()
	# Starting a simulation leaves comment mode: restore the editor tool (so drawing works again
	# after the sim) and re-pick the previous ink.
	if is_simulation_requested and _active:
		_leave(true, true)


# --- board input (place / edit / delete, click AND drag) --------------------------------------
func _ev_ui_context_change(_mode: int, _args: Dictionary) -> void :
	var p_stable_context: int = _args[E.ui_context_change.p_stable_context]
	_is_world_frame = p_stable_context == C.CONTEXT.WORLD_FRAME


func _ev_mi_mouse_input_on_board(_mode: int, _args: Dictionary) -> void :
	if _sync == null:
		return
	var p_position: Vector2 = _args[E.mi_mouse_input_on_board.p_position]
	var p_is_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_pressed]
	var p_is_just_pressed: bool = _args[E.mi_mouse_input_on_board.p_is_just_pressed]
	var p_is_just_released: bool = _args[E.mi_mouse_input_on_board.p_is_just_released]
	var p_is_left_click: bool = _args[E.mi_mouse_input_on_board.p_is_left_click]
	# A zone-move drag (started in _input with the selection tool) takes priority over comment
	# drawing — it's mutually exclusive (the comment ink isn't active during a move).
	if _move_active:
		_handle_move_input(p_position, p_is_pressed, p_is_just_released, p_is_left_click)
		return
	if not _active:
		return
	if _editor != null and not bool(_editor.get("is_in_editor")):
		return
	if p_is_just_released:
		_drag_place = false
		_drag_erase = false
		# Drawing finished: recompute group geometry / T positions ONCE now (they were left alone
		# during the drag to keep it smooth).
		_geom_dirty = true
		update()
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
				_place_footprint(cell)
				_drag_place = true
		elif p_is_pressed and _drag_place:
			_place_footprint(cell)
	else:
		# Right button erases (click + drag), like erasing a trace — a footprint of the chosen
		# tile size (4x4 or 8x8), so deleting matches the size you place with.
		if p_is_just_pressed:
			_drag_erase = true
		if _drag_erase:
			_erase_footprint(cell)


# --- moving a whole zone with the selection tool ----------------------------------------------
# Begin a zone move when the SELECTION tool is active and the press lands on a comment cell. Runs in
# _input (before cursor_board echoes the board event), so pinning the editor tool to NONE here means
# the editor's own handler — which runs on that echo — sees NONE and never starts a selection box.
# We do NOT consume the event: the echo still fires so _ev_mi_mouse_input_on_board can track the drag.
func _input(event: InputEvent) -> void :
	if _active or _move_active or _sync == null or _editor == null:
		return
	if not (event is InputEventMouseButton):
		return
	if event.button_index != BUTTON_LEFT or not event.pressed:
		return
	if not _is_world_frame or not bool(_editor.get("is_in_editor")):
		return
	if int(_editor.get("editor_tool")) != Editor.TOOL.SELECTION:
		return
	var board_pos := get_global_mouse_position().floor()
	if not C.CIRCUIT.RECT.has_point(board_pos):
		return
	var cell: Vector2 = _sync.cell_of(board_pos)
	if not _sync.has_block(cell):
		return  # empty board → let the selection tool select normally
	_move_active = true
	_move_member = cell
	_move_press_cell = cell
	_move_delta = Vector2(0, 0)
	_move_cells = _sync.group_cells(cell)
	_move_restore_tool = Editor.TOOL.SELECTION
	# Pin the editor tool to NONE so the selection tool doesn't act during the move.
	_editor.set("editor_tool", Editor.TOOL.NONE)
	update()


func _handle_move_input(p_position: Vector2, p_is_pressed: bool, p_is_just_released: bool, p_is_left_click: bool) -> void :
	# Right-click (or any non-left press) during a move cancels it, leaving the group where it was.
	if not p_is_left_click and (p_is_pressed or p_is_just_released):
		_end_move(true)
		return
	if p_is_just_released:
		_finish_move()
		return
	# Track the tentative delta (in cells) from the press cell; the group stays put until release.
	var cell: Vector2 = _sync.cell_of(p_position)
	var new_delta: Vector2 = cell - _move_press_cell
	if new_delta != _move_delta:
		_move_delta = new_delta
		update()
	Input.set_default_cursor_shape(Input.CURSOR_DRAG)


# Commit the move on release (if the drop is allowed); otherwise the group stays put. Either way the
# selection tool is restored and geometry rebuilt.
func _finish_move() -> void :
	if (int(_move_delta.x) != 0 or int(_move_delta.y) != 0) and _sync.has_method("move_group"):
		var _ok = _sync.move_group(_move_member, _move_delta, true)
	_end_move(true)


# Abandon an in-progress move because a tool change / simulation start took over: the interrupting
# event already set the editor tool, so DON'T restore it here (just drop the pending move).
func _abandon_move() -> void :
	_end_move(false)


# Common teardown: clear move state, optionally restore the pinned editor tool (only when the move
# ended on its own — not when an external tool/mode change already replaced it), refresh geometry.
func _end_move(restore_tool: bool) -> void :
	_move_active = false
	_move_cells = []
	_move_delta = Vector2(0, 0)
	if restore_tool and _editor != null and _move_restore_tool >= 0:
		_editor.set("editor_tool", _move_restore_tool)
	_move_restore_tool = -1
	_geom_dirty = true
	update()


# Place every not-yet-present cell of the current brush footprint anchored at `origin`.
func _place_footprint(origin: Vector2) -> void :
	for c in _footprint_cells(origin):
		if not _sync.has_block(c):
			_sync.place(c, true)


# Remove every present cell of the current brush footprint anchored at `origin` (so a
# right-click/drag deletes at the chosen 4x4 / 8x8 tile size).
func _erase_footprint(origin: Vector2) -> void :
	for c in _footprint_cells(origin):
		if _sync.has_block(c):
			_sync.remove(c, true)


func _open_editor(cell: Vector2) -> void :
	if _window == null:
		return
	var anchor: Vector2 = _sync.anchor_of(cell)
	if anchor.x < 0:
		return
	if _window.has_method("open_for"):
		_window.open_for(anchor)
