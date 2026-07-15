extends TextureButton

# comment_ink_button.gd — a Comment Block entry for the ink palette (right bar) and the Q/A quick
# menu, so the comment block can be picked like any ink/component.
#
# It's a toggle TextureButton with a small generated icon (a translucent card with two quote
# marks). mod_main adds it to the ink bar and to the quick menu, joins it to the same ButtonGroup
# as the inks (so selecting it deselects the inks and vice-versa), and connects its `toggled` to
# the overlay's comment-mode toggle. It also exposes the couple of methods the quick menu calls on
# its buttons (public_unhover / public_enable_ink_switch_usage / public_enable_filter_usage) so it
# can live in that menu's button list too.

const ICON_SIZE := 28


func _ready() -> void :
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	expand = true
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	rect_min_size = Vector2(28, 22)
	hint_tooltip = "Comment block — place notes on the board (editor-only, never simulated)"
	var tex := _make_texture(false)
	var tex_on := _make_texture(true)
	texture_normal = tex
	texture_hover = tex_on
	texture_pressed = tex_on


func _make_texture(active: bool) -> ImageTexture:
	var s := ICON_SIZE
	var img := Image.new()
	img.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var frame := Color(0.882, 0.745, 0.514, 1.0)
	var fill := Color(0.882, 0.745, 0.514, 0.5 if active else 0.22)
	var glyph := Color(0.10, 0.09, 0.06, 1.0)
	img.lock()
	for x in s:
		for y in s:
			var edge: bool = x < 2 or y < 2 or x >= s - 2 or y >= s - 4
			var inside: bool = x >= 2 and y >= 2 and x < s - 2 and y < s - 4
			if edge:
				img.set_pixel(x, y, frame)
			elif inside:
				img.set_pixel(x, y, fill)
	# Two little quote marks so it reads as a comment.
	for gx in [8, 15]:
		for dx in range(3):
			for dy in range(5):
				var px := gx + dx
				var py := 9 + dy
				if px < s and py < s:
					img.set_pixel(px, py, glyph)
	img.unlock()
	var t := ImageTexture.new()
	t.create_from_image(img, 0)
	return t


# The quick menu calls these on the buttons in its list; provide no-op / minimal versions so this
# button can be added to that list without erroring.
func public_unhover() -> void :
	pass


func public_enable_ink_switch_usage() -> void :
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_button_mask(0)
	hint_tooltip = ""


func public_enable_filter_usage() -> void :
	pass
