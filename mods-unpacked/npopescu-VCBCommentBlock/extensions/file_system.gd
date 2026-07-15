extends "res://src/editor/file_system.gd"

# Comment Block — persist comment blocks inside the saved .vcb, under the shared "modded" field.
#
# VCB projects are JSON; the vanilla loader copies every top-level key from the file, so an extra
# namespaced key round-trips untouched. This is the same shared convention the Board Size Modifier
# uses (see that mod's CLAUDE.md): each mod stores its own data under its own id, and both mods can
# extend file_system.gd side by side because each only ever touches its OWN key under "modded" and
# always calls the base method.
#
#   "modded": { "npopescu-VCBCommentBlock": { "cells": [[cx,cy],…], "texts": {"cx,cy": "…"} }, … }
#
# On save we merge our entry (or drop it, and an emptied container, when there are no blocks — so a
# comment-free board stays a clean, vanilla-openable file). On load we restore the blocks after the
# base finishes reading the project.

const _CB_MOD_ID := "npopescu-VCBCommentBlock"
const _CB_MODDED_KEY := "modded"


func save_file(path: String, savemode: int) -> void :
	_cb_stamp_modded(project)
	.save_file(path, savemode)


func _cb_stamp_modded(d) -> void :
	if typeof(d) != TYPE_DICTIONARY:
		return
	var sync_node := _cb_sync()
	var modded = d.get(_CB_MODDED_KEY)
	if typeof(modded) != TYPE_DICTIONARY:
		modded = {}
	if sync_node != null and sync_node.has_method("is_empty") and not sync_node.is_empty():
		modded[_CB_MOD_ID] = sync_node.export_state()
	else:
		var _e = modded.erase(_CB_MOD_ID)
	if modded.empty():
		var _e2 = d.erase(_CB_MODDED_KEY)
	else:
		d[_CB_MODDED_KEY] = modded


func open_file(path: String) -> void :
	.open_file(path)
	_cb_restore()


func _cb_restore() -> void :
	var sync_node := _cb_sync()
	if sync_node == null or not sync_node.has_method("import_state"):
		return
	var data = null
	if typeof(project) == TYPE_DICTIONARY:
		var modded = project.get(_CB_MODDED_KEY)
		if typeof(modded) == TYPE_DICTIONARY:
			data = modded.get(_CB_MOD_ID)
	# import_state clears first, so a project with no entry correctly loads as "no comments".
	sync_node.import_state(data)
	# In a live multiplayer session, share the freshly loaded comments with the peer.
	if sync_node.has_method("broadcast_full_state"):
		sync_node.broadcast_full_state()


func _cb_sync() -> Node:
	return get_tree().root.get_node_or_null("CommentBlockSync")
