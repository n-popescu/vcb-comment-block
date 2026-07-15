extends TextureButton

# comment_ink_button.gd — the Comment Block entry in the ink palette (right bar, "Annotation" row)
# and in the Q/A quick menu.
#
# This is a faithful clone of the game's own ink button (src/gui/sidepanels/circuit_editor/
# button_ink.gd): a real ink whose "type id" (indexed_color_id) is "COMMENT". Selecting it emits
# the same ed_indexed_color_change / ed_indexed_color_pick events every native ink emits, so the
# game treats it as THE selected ink — it joins the ink ButtonGroup, deselects the previous ink,
# and re-presses itself when "COMMENT" is picked from anywhere (the palette, the Q/A menu, an
# eyedrop, …). mod_main registers the matching "COMMENT" entry in C.PALETTE (the ink "variables")
# before this button is built, so the accent tint reads straight from the palette like any ink.
#
# The comment ink is NOT painted onto the board: comment_block_overlay.gd watches for the "COMMENT"
# ink becoming active and, while it is, holds the editor tool at NONE (so nothing is painted) and
# places editor-only comment blocks itself. That keeps the comment ink purely a decoration that the
# simulation engine never sees.

const COMMENT_ID := "COMMENT"
const ICON_PATH := "res://assets/icons/18px/text_symbol.png"
const FLUX_TSCN := "res://src/gui/flux/flux_mod_btn_texture.tscn"
const MAIN_THEME := "res://src/gui/themes/main_theme.tres"

# Fallback tint used only if the "COMMENT" palette entry somehow isn't registered. A warm note/
# sticky tan that no vanilla ink uses (kept in sync with the overlay's BLOCK_* colours and the
# palette entry mod_main registers).
const COMMENT_ACCENT := Color("e1be83")

# The button's ink "type id" — mirrors the exported var on the native ink buttons.
var indexed_color_id := COMMENT_ID
var is_filter_usage := false

var _flux: Node = null

# Right-click size menu (set only on the palette button; the overlay is the shared size owner).
var _overlay: Node = null
var _size_popup: Popup = null


func _ready() -> void :
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	expand = true
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	if rect_min_size == Vector2.ZERO:
		rect_min_size = Vector2(26, 26)
	if hint_tooltip == "":
		hint_tooltip = "Comment — annotate the board (editor-only, never simulated)"
	if texture_normal == null:
		texture_normal = _load_icon()
	E.follow_events(self, [
		E.ed_indexed_color_pick,
	])
	var _e = connect("toggled", self, "_on_button_toggled")
	# Right-click opens a small text menu to choose the comment tile size (4x4 / 8x8) — the same
	# gesture the game's clock/timer/etc. ink buttons use to open their options popup.
	var _gi = connect("gui_input", self, "_on_gui_input")
	# The native ink accent overlay (background panel + hover/press tinting). Built as a child so it
	# behaves exactly like $FluxModTextureButton on a native ink button.
	_flux = _make_flux()
	if _flux != null:
		add_child(_flux)
		if _flux.has_method("public_set_inkmode_accent"):
			_flux.public_set_inkmode_accent(_accent())


# The comment ink's accent colour — read from the registered palette entry, or the fallback tan.
func _accent() -> Color:
	if typeof(C.PALETTE) == TYPE_DICTIONARY and C.PALETTE.has(indexed_color_id):
		var entry = C.PALETTE[indexed_color_id]
		if typeof(entry) == TYPE_DICTIONARY and entry.has("ON"):
			return Color(entry["ON"])
	return COMMENT_ACCENT


# Picked (pressed) → announce the comment ink as the selected ink, exactly like a native ink does.
func _on_button_toggled(new_state: bool) -> void :
	if is_filter_usage:
		return
	if indexed_color_id == "":
		return
	if new_state:
		E.echo(E.ed_indexed_color_change, {
			E.ed_indexed_color_change.p_indexed_color_id: indexed_color_id, })
		E.echo(E.ed_indexed_color_pick, {
			E.ed_indexed_color_pick.p_indexed_color_id: indexed_color_id, })


# The comment ink was picked from somewhere else (the other bar, prev/next, …) → reflect it here,
# so the palette and the Q/A menu stay in sync just like the native inks.
func _ev_ed_indexed_color_pick(_mode: int, _args: Dictionary) -> void :
	var p_indexed_color_id: String = _args[E.ed_indexed_color_pick.p_indexed_color_id]
	if is_filter_usage:
		return
	if indexed_color_id == "":
		return
	if indexed_color_id == p_indexed_color_id:
		pressed = true


# --- methods the ink bars / quick menu call on their ink buttons ------------------------------
func public_unhover() -> void :
	if _flux != null and _flux.has_method("public_inkmode_set_hovered_false"):
		_flux.public_inkmode_set_hovered_false()


func public_enable_ink_switch_usage() -> void :
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_button_mask(0)
	hint_tooltip = ""


func public_enable_filter_usage() -> void :
	is_filter_usage = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_button_mask(0)
	hint_tooltip = ""
	group = null


func public_set_pressed_no_event(p_is_pressed: bool) -> void :
	var temp_indexed_color_id := indexed_color_id
	indexed_color_id = ""
	pressed = p_is_pressed
	indexed_color_id = temp_indexed_color_id


# --- right-click size menu (4x4 / 8x8) --------------------------------------------------------
# mod_main calls this (on the palette button only) with the overlay, so the menu can set the shared
# placement brush size. Building the popup now (not lazily) lets its layout settle before use.
func set_size_menu_target(overlay: Node) -> void :
	_overlay = overlay
	if _size_popup == null:
		_size_popup = _build_size_menu()
		add_child(_size_popup)


func _on_gui_input(event: InputEvent) -> void :
	if _overlay == null or _size_popup == null:
		return
	if event is InputEventMouseButton and not event.pressed and event.button_index == BUTTON_RIGHT:
		_open_size_menu()


func _open_size_menu() -> void :
	_size_popup.set_as_minsize()
	var pns: Vector2 = _size_popup.rect_size
	var pos: Vector2 = rect_global_position
	# Centered above the button (like the stock option popups).
	_size_popup.popup(Rect2(pos.x + rect_size.x / 2.0 - pns.x / 2.0, pos.y - pns.y - 4.0, pns.x, pns.y))


func _build_size_menu() -> Popup:
	var pop := Popup.new()
	pop.name = "CommentSizeMenu"
	if ResourceLoader.exists(MAIN_THEME):
		var th = load(MAIN_THEME)
		if th is Theme:
			pop.theme = th
	var panel := PanelContainer.new()
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.add_stylebox_override("panel", _menu_panel_style())
	pop.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_constant_override("margin_left", 8)
	margin.add_constant_override("margin_right", 8)
	margin.add_constant_override("margin_top", 6)
	margin.add_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_constant_override("separation", 4)
	margin.add_child(vb)
	var head := Label.new()
	head.text = "Comment tile"
	head.align = Label.ALIGN_CENTER
	vb.add_child(head)
	var b4 := Button.new()
	b4.text = "4x4"
	b4.focus_mode = Control.FOCUS_NONE
	var _e4 = b4.connect("pressed", self, "_on_size_chosen", [4])
	vb.add_child(b4)
	var b8 := Button.new()
	b8.text = "8x8"
	b8.focus_mode = Control.FOCUS_NONE
	var _e8 = b8.connect("pressed", self, "_on_size_chosen", [8])
	vb.add_child(b8)
	pop.rect_min_size = Vector2(96, 0)
	return pop


func _menu_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0745098, 0.0941176, 0.12549, 1)
	sb.border_color = Color(0.164706, 0.207843, 0.254902, 1)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_default_margin(MARGIN_LEFT, 4)
	sb.set_default_margin(MARGIN_TOP, 4)
	sb.set_default_margin(MARGIN_RIGHT, 4)
	sb.set_default_margin(MARGIN_BOTTOM, 4)
	return sb


func _on_size_chosen(px: int) -> void :
	if _overlay != null and _overlay.has_method("set_brush_size"):
		_overlay.set_brush_size(px)
	if _size_popup != null:
		_size_popup.hide()


# --- icon ------------------------------------------------------------------------------------
# The game's icons are white glyphs (the flux accent colours them); load the stock text glyph, or
# fall back to a generated speech-bubble if it's somehow missing.
func _load_icon() -> Texture:
	if ResourceLoader.exists(ICON_PATH):
		var t = load(ICON_PATH)
		if t is Texture:
			return t
	return _fallback_icon()


func _fallback_icon() -> ImageTexture:
	var s := 18
	var img := Image.new()
	img.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var w := Color(1, 1, 1, 1)
	img.lock()
	for x in range(2, s - 2):
		img.set_pixel(x, 3, w)
		img.set_pixel(x, s - 6, w)
	for y in range(3, s - 5):
		img.set_pixel(2, y, w)
		img.set_pixel(s - 3, y, w)
	img.set_pixel(5, s - 5, w)
	img.set_pixel(5, s - 4, w)
	img.set_pixel(6, s - 5, w)
	img.unlock()
	var tex := ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _make_flux() -> Node:
	if not ResourceLoader.exists(FLUX_TSCN):
		return null
	var scn = load(FLUX_TSCN)
	if scn == null:
		return null
	var inst = scn.instance()
	if inst != null:
		inst.name = "FluxModTextureButton"
	return inst
