extends Node

# mod_main.gd — Mod Loader entry point for the VCB Comment Block mod.
#
# Adds an editor-only "comment block": a block you place on the board that shows a text comment on
# hover and opens an editor popup on click. Comment blocks are NEVER sent to the simulation engine
# (they're pure editor decoration, kept in a mod-owned overlay, not on the circuit layers), so they
# don't affect the circuit. Adjacent blocks merge into one comment. Everything is synced over the
# Multiplayer mod when a session is live, and persisted inside the .vcb file.
#
# The comment block is a real ink: it appears in the palette's "Annotation" row (between Filler and
# None) and in the Q/A quick menu (between Filler and None), joined to the inks' ButtonGroup. Pick
# it like any ink and draw comment blocks with the mouse (see comment_block_overlay.gd).
#
# Like the Board Size Modifier's mod_main, this waits for the Main scene and grafts on its own
# nodes:
#   • /root/CommentBlockSync   — the data model + MP RPC node (stable path so rpc() resolves).
#   • Main/World/CommentBlockOverlay — draws the blocks + the hover tooltip, routes board input.
#   • Main/CommentBlockUI (CanvasLayer) → CommentEditWindow — the editor popup.
#   • the comment ink entries in the palette + quick menu.
# It also installs a file_system script extension to save/load the blocks in the .vcb.

const MOD_DIR := "npopescu-VCBCommentBlock"
const MOD_ROOT := "res://mods-unpacked/npopescu-VCBCommentBlock"
const SCRIPTS := MOD_ROOT + "/scripts"
const EXTENSIONS := MOD_ROOT + "/extensions"
const MAIN_THEME := "res://src/gui/themes/main_theme.tres"

var _core_built := false
var _palette_wired := false
var _quickmenu_wired := false
# The circuit-editor panel and the quick menu build themselves a little after Main appears (docking
# instances the side panels, the menu fills its `buttons` list in its own _ready), so we keep
# retrying the ink wiring for a while rather than giving up after one frame.
var _wire_frames := 0
const _WIRE_LIMIT := 1800  # ~30 s at 60 fps, then stop trying

var _main: Node = null
var _overlay: Node = null


func _init() -> void :
	ModLoaderLog.info("Installing VCB Comment Block…", MOD_DIR)
	# Persist comment blocks inside saved .vcb files (shared "modded" field). Targets a script the
	# Multiplayer mod does not extend; the Board Size mod also extends it, and both coexist because
	# each only touches its own key under "modded" and calls the base method.
	ModLoaderMod.install_script_extension(EXTENSIONS + "/file_system.gd")


func _ready() -> void :
	set_process(true)


func _process(_delta: float) -> void :
	if not _core_built:
		if not _build_core():
			return
	# Keep trying to wire the palette + quick-menu ink entries until both are in place.
	if not _palette_wired:
		_palette_wired = _wire_palette()
	if not _quickmenu_wired:
		_quickmenu_wired = _wire_quickmenu()
	_wire_frames += 1
	if _palette_wired and _quickmenu_wired:
		ModLoaderLog.info("Comment ink added to the ink palette + Q/A quick menu.", MOD_DIR)
		set_process(false)
	elif _wire_frames > _WIRE_LIMIT:
		ModLoaderLog.warning(
			"Gave up wiring the comment ink (palette=%s, quickmenu=%s)." % [_palette_wired, _quickmenu_wired],
			MOD_DIR)
		set_process(false)


# Build the always-needed nodes (data model, overlay, editor popup). Returns true once done.
func _build_core() -> bool:
	var root := get_tree().root
	var main := root.get_node_or_null("Main")
	if main == null:
		return false
	var editor := main.get_node_or_null("Systems/Editor")
	if editor == null:
		editor = main.find_node("Editor", true, false)
	var world := main.get_node_or_null("World")
	if editor == null or world == null:
		return false
	_main = main

	var theme_res = load(MAIN_THEME)

	# 1) The data + MP sync node, at a stable path so rpc() resolves on both peers.
	# NOTE: never name a local `sync` — it's a reserved GDScript RPC keyword and the whole script
	# fails to compile (which silently kills the mod).
	var sync_node: Node = root.get_node_or_null("CommentBlockSync")
	if sync_node == null:
		sync_node = _new_script(SCRIPTS + "/comment_block_sync.gd")
		if sync_node == null:
			return false
		sync_node.name = "CommentBlockSync"
		root.add_child(sync_node)

	# 2) The editor popup, on its own CanvasLayer so it floats above the board.
	var window: Node = null
	if main.get_node_or_null("CommentBlockUI") == null:
		var layer := CanvasLayer.new()
		layer.name = "CommentBlockUI"
		layer.layer = 129
		window = _new_script(SCRIPTS + "/gui/comment_edit_window.gd")
		if window != null:
			window.name = "CommentEditWindow"
			if theme_res is Theme:
				window.theme = theme_res
			layer.add_child(window)
		main.add_child(layer)
		if window != null and window.has_method("setup"):
			window.setup(sync_node)
	else:
		window = main.get_node_or_null("CommentBlockUI/CommentEditWindow")

	# 3) The on-board overlay (draw + hover tooltip + input routing), sharing the board's space.
	var overlay: Node = world.get_node_or_null("CommentBlockOverlay")
	if overlay == null:
		overlay = _new_script(SCRIPTS + "/comment_block_overlay.gd")
		if overlay == null:
			return false
		overlay.name = "CommentBlockOverlay"
		if overlay.has_method("setup"):
			overlay.setup(sync_node, editor, window)
		world.add_child(overlay)
	_overlay = overlay

	_core_built = true
	return true


# Palette entry: a comment ink in the right-bar's "Annotation" row (HBoxContainer6), inserted
# between Filler and None, sharing the inks' ButtonGroup so it selects/deselects like any ink.
func _wire_palette() -> bool:
	if _main == null or _overlay == null:
		return false
	var inks := _main.find_node("Inks", true, false)
	if inks == null:
		return false
	var vbox := inks.get_node_or_null("VBoxContainer")
	if vbox == null:
		return false
	var row := vbox.get_node_or_null("HBoxContainer6")  # the "Annotation" row
	if row == null:
		return false
	if row.get_node_or_null("BtnCommentInk") != null:
		return true
	var none_btn = row.get_node_or_null("BtnNone")
	var btn = _make_comment_button(Vector2(28, 0))
	if btn == null:
		return false
	var grp = _group_of(none_btn)
	if grp != null:
		btn.group = grp
	row.add_child(btn)
	if none_btn != null:
		row.move_child(btn, none_btn.get_index())  # place it just before None
	_overlay.register_button(btn)
	return true


# Quick-menu entry (the Q/A ink-switch menu): a comment button in HFlowContainer2 between Filler
# and None, joined to the menu's runtime ButtonGroup and appended to its hover-selectable `buttons`.
func _wire_quickmenu() -> bool:
	if _main == null or _overlay == null:
		return false
	var qm := _main.get_node_or_null("Interface/GUI/InkSwitchMenu")
	if qm == null:
		return false
	var flow := qm.get_node_or_null("PanelContainer/HBoxContainer/HFlowContainer2")
	if flow == null:
		return false
	if flow.get_node_or_null("BtnCommentInk") != null:
		return true
	# Wait until the menu has built its `buttons` list + ButtonGroup in its own _ready.
	if not ("buttons" in qm) or typeof(qm.buttons) != TYPE_ARRAY or qm.buttons.empty():
		return false
	var none_btn = flow.get_node_or_null("BtnNone")
	var btn = _make_comment_button(Vector2(26, 26))
	if btn == null:
		return false
	var grp = _group_of(qm.buttons[0])
	if grp != null:
		btn.group = grp
	flow.add_child(btn)
	if none_btn != null:
		flow.move_child(btn, none_btn.get_index())  # place it just before None
	if btn.has_method("public_enable_ink_switch_usage"):
		btn.public_enable_ink_switch_usage()
	qm.buttons.append(btn)
	_overlay.register_button(btn)
	return true


# Instance the comment ink button at the given minimum size (matching its neighbours in each bar).
func _make_comment_button(min_size: Vector2) -> Node:
	var btn = _new_script(SCRIPTS + "/comment_ink_button.gd")
	if btn == null:
		return null
	btn.name = "BtnCommentInk"
	btn.rect_min_size = min_size  # set before it enters the tree so _ready keeps it
	return btn


# The ButtonGroup a given ink button belongs to (or null).
func _group_of(button):
	if button != null and button.get("group") != null:
		return button.group
	return null


# Instance a mod script, or null (logged) if it can't be loaded — never dereference a null.
func _new_script(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_warning("[VCB-CommentBlock] missing script, skipping: " + path)
		return null
	var scr = load(path)
	if scr == null:
		push_warning("[VCB-CommentBlock] failed to load script: " + path)
		return null
	var inst = scr.new()
	if inst == null:
		push_warning("[VCB-CommentBlock] failed to instance script: " + path)
		return null
	return inst
