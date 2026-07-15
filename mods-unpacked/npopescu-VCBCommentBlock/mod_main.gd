extends Node

# mod_main.gd — Mod Loader entry point for the VCB Comment Block mod.
#
# Adds an editor-only "comment block": a block you place on the board that shows a text comment on
# hover and opens an editor popup on click. Comment blocks are NEVER sent to the simulation engine
# (they're pure editor decoration, kept in a mod-owned overlay, not on the circuit layers), so they
# don't affect the circuit. Adjacent blocks merge into one comment. Everything is synced over the
# Multiplayer mod when a session is live, and persisted inside the .vcb file.
#
# Like the Board Size Modifier's mod_main, this waits for the Main scene and grafts on its own
# nodes:
#   • /root/CommentBlockSync   — the data model + MP RPC node (stable path so rpc() resolves).
#   • Main/World/CommentBlockOverlay — draws the blocks + the hover tooltip, routes board clicks.
#   • Main/CommentBlockUI (CanvasLayer) → CommentEditWindow — the editor popup.
#   • a "Comment" toggle button in the toolbar that turns comment (place/edit) mode on.
# It also installs a file_system script extension to save/load the blocks in the .vcb.

const MOD_DIR := "npopescu-VCBCommentBlock"
const MOD_ROOT := "res://mods-unpacked/npopescu-VCBCommentBlock"
const SCRIPTS := MOD_ROOT + "/scripts"
const EXTENSIONS := MOD_ROOT + "/extensions"
const MAIN_THEME := "res://src/gui/themes/main_theme.tres"

var _built := false


func _init() -> void :
	ModLoaderLog.info("Installing VCB Comment Block…", MOD_DIR)
	# Persist comment blocks inside saved .vcb files (shared "modded" field). Targets a script the
	# Multiplayer mod does not extend; the Board Size mod also extends it, and both coexist because
	# each only touches its own key under "modded" and calls the base method.
	ModLoaderMod.install_script_extension(EXTENSIONS + "/file_system.gd")


func _ready() -> void :
	set_process(true)


func _process(_delta: float) -> void :
	if _built:
		set_process(false)
		return
	var root := get_tree().root
	var main := root.get_node_or_null("Main")
	if main == null:
		return
	var editor := main.get_node_or_null("Systems/Editor")
	if editor == null:
		editor = main.find_node("Editor", true, false)
	var world := main.get_node_or_null("World")
	var file_controls := main.find_node("FileControls", true, false)
	if editor == null or world == null or file_controls == null:
		return
	_built = true
	set_process(false)
	_build(root, main, editor, world, file_controls)


func _build(root: Node, main: Node, editor: Node, world: Node, file_controls: Node) -> void :
	var theme_res = load(MAIN_THEME)

	# 1) The data + MP sync node, at a stable path so rpc() resolves on both peers.
	var sync: Node = root.get_node_or_null("CommentBlockSync")
	if sync == null:
		sync = _new_script(SCRIPTS + "/comment_block_sync.gd")
		if sync == null:
			return
		sync.name = "CommentBlockSync"
		root.add_child(sync)

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
			window.setup(sync)
	else:
		window = main.get_node_or_null("CommentBlockUI/CommentEditWindow")

	# 3) The on-board overlay (draw + hover tooltip + click routing), sharing the board's space.
	var overlay: Node = world.get_node_or_null("CommentBlockOverlay")
	if overlay == null:
		overlay = _new_script(SCRIPTS + "/comment_block_overlay.gd")
		if overlay == null:
			return
		overlay.name = "CommentBlockOverlay"
		if overlay.has_method("setup"):
			overlay.setup(sync, editor, window)
		world.add_child(overlay)

	# 4) A toolbar toggle button that turns comment mode on/off.
	if file_controls.get_node_or_null("BtnComment") == null:
		var btn := Button.new()
		btn.name = "BtnComment"
		btn.text = "Comment"
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.hint_tooltip = "Comment blocks: click an empty spot to place one, click a block to edit its text, right-click to delete. Adjacent blocks share one comment. Hover any block to read it."
		if theme_res is Theme:
			btn.theme = theme_res
		file_controls.add_child(btn)
		if overlay != null:
			overlay.register_button(btn)

	# 5) Palette entry: a comment "ink" in the right-bar ink grid, sharing the inks' ButtonGroup so
	#    it selects/deselects like any other ink.
	var inks := main.find_node("Inks", true, false)
	if inks != null:
		var ink_vbox := inks.get_node_or_null("VBoxContainer")
		if ink_vbox != null and ink_vbox.get_node_or_null("CommentInkRow") == null:
			var grp = _find_ink_group(ink_vbox)
			var row := HBoxContainer.new()
			row.name = "CommentInkRow"
			var pbtn = _new_script(SCRIPTS + "/comment_ink_button.gd")
			if pbtn != null:
				pbtn.name = "BtnCommentInk"
				if grp != null:
					pbtn.group = grp
				row.add_child(pbtn)
				ink_vbox.add_child(row)
				if overlay != null:
					overlay.register_button(pbtn)

	# 6) Quick-menu entry (the Q/A ink-switch radial): add a comment button to its button list so
	#    it's hover-selectable there too.
	var qm := main.get_node_or_null("Interface/GUI/InkSwitchMenu")
	if qm != null:
		var flow := qm.get_node_or_null("PanelContainer/HBoxContainer/HFlowContainer")
		if flow != null and flow.get_node_or_null("BtnCommentInk") == null:
			var qbtn = _new_script(SCRIPTS + "/comment_ink_button.gd")
			if qbtn != null:
				qbtn.name = "BtnCommentInk"
				var qgrp = _quickmenu_group(qm)
				if qgrp != null:
					qbtn.group = qgrp
				flow.add_child(qbtn)
				if qbtn.has_method("public_enable_ink_switch_usage"):
					qbtn.public_enable_ink_switch_usage()
				# Make it hover-selectable like the menu's own buttons.
				if ("buttons" in qm) and typeof(qm.buttons) == TYPE_ARRAY:
					qm.buttons.append(qbtn)
				if overlay != null:
					overlay.register_button(qbtn)


# The ButtonGroup shared by the ink-bar's ink buttons (read off the first grouped TextureButton).
func _find_ink_group(ink_vbox: Node):
	for hbox in ink_vbox.get_children():
		for child in hbox.get_children():
			if child is TextureButton and child.group != null:
				return child.group
	return null


# The ButtonGroup the quick menu built for its buttons (assigned in its _ready).
func _quickmenu_group(qm: Node):
	if ("buttons" in qm) and typeof(qm.buttons) == TYPE_ARRAY and qm.buttons.size() > 0:
		var b = qm.buttons[0]
		if b != null:
			return b.group
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
