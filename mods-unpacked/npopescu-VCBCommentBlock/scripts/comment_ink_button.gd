extends TextureButton

# comment_ink_button.gd — the Comment Block entry in the ink palette (right bar, "Annotation" row)
# and the Q/A quick menu. It is a real ink-style toggle button: you pick it like any other ink and
# then draw comment blocks on the board with it (see comment_block_overlay.gd). It is NOT a separate
# "mode" — selecting it deselects the current ink (they share the ButtonGroup), and picking any
# other ink deselects it.
#
# To look and behave exactly like a native ink button it is a TextureButton with the game's white
# glyph icon (tinted by a FluxModTextureButton accent, just like button_ink.gd), and it exposes the
# handful of public_* methods the ink-switch quick menu calls on the buttons in its list.

const ICON_PATH := "res://assets/icons/18px/text_symbol.png"
const FLUX_TSCN := "res://src/gui/flux/flux_mod_btn_texture.tscn"

# The comment "ink" colour. Deliberately a warm note/sticky tan that no vanilla ink uses, so a
# comment block reads as an annotation rather than a circuit component. Kept in sync with the
# overlay's BLOCK_* colours.
const COMMENT_COLOR := Color("e1be83")

var _flux: Node = null


func _ready() -> void :
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	expand = true
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	if rect_min_size == Vector2.ZERO:
		rect_min_size = Vector2(26, 26)
	if hint_tooltip == "":
		hint_tooltip = "Comment block — annotate the board (editor-only, never simulated)"
	texture_normal = _load_icon()
	# The native ink accent overlay (background panel + hover/press tinting). Tints this button's
	# white glyph to the comment colour, matching every other ink button.
	_flux = _make_flux()
	if _flux != null:
		add_child(_flux)
		if _flux.has_method("public_set_inkmode_accent"):
			_flux.public_set_inkmode_accent(COMMENT_COLOR)


# The game's icons are white glyphs (the accent overlay colours them); load the stock text glyph,
# or fall back to a generated one if it's somehow missing.
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
	# A small speech-bubble outline so it reads as a "comment".
	for x in range(2, s - 2):
		img.set_pixel(x, 3, w)
		img.set_pixel(x, s - 6, w)
	for y in range(3, s - 5):
		img.set_pixel(2, y, w)
		img.set_pixel(s - 3, y, w)
	# Little tail.
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


# --- methods the ink-switch quick menu calls on its buttons ----------------------------------
func public_unhover() -> void :
	if _flux != null and _flux.has_method("public_inkmode_set_hovered_false"):
		_flux.public_inkmode_set_hovered_false()


func public_enable_ink_switch_usage() -> void :
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_button_mask(0)


func public_enable_filter_usage() -> void :
	pass
