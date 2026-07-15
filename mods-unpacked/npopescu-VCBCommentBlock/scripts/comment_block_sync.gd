extends Node

# comment_block_sync.gd — the data model + multiplayer sync point for the Comment Block mod.
#
# Lives at /root/CommentBlockSync (a stable path so rpc() resolves on both peers). It owns ALL
# comment-block state and is the single source of truth the overlay draws from and the edit window
# reads/writes through. It never edits the circuit layers — comment blocks are editor-only decor
# that the simulation engine never sees.
#
# Data model
# ----------
# Comment blocks snap to a coarse grid of CELL_SIZE board pixels. A "block" is one occupied cell.
# Blocks that are 4-neighbour adjacent form one COMMENT GROUP (a connected component) that shares a
# single text — hovering or clicking any cell of a group acts on the whole group, as if it were one
# bigger block. Each group's text is stored at its ANCHOR cell (top-most, then left-most), so the
# text follows the group as it grows/shrinks.
#
#   _cells : { "cx,cy": true }              every occupied cell
#   _texts : { "<anchor cx,cy>": "text" }   one entry per non-empty group, keyed by its anchor
#
# Multiplayer
# -----------
# When the VCB Multiplayer mod has a live peer, placements / removals / live text edits are mirrored
# over its ENet peer (this mod never opens its own), and the host pushes the whole state to a late
# joiner. All MP calls are guarded by _live_session() via get_node_or_null/Object.get, so the mod
# works fine with the Multiplayer mod absent.

const CELL_SIZE := 8

var _cells := {}
var _texts := {}

var _applying_remote := false

# Multiplayer hook (mod load order isn't fixed, so poll for the MP autoload, then connect once).
var _mp_hooked := false
var _mp_poll_frames := 0
const _MP_POLL_LIMIT := 3600  # ~1 min at 60 fps, then give up (MP mod simply isn't installed)

signal blocks_changed
signal text_changed(anchor_key, text)


func _ready() -> void :
	E.follow_events(self, [
		E.fs_project_change,
	])
	set_process(true)


func _process(_delta: float) -> void :
	if _mp_hooked:
		set_process(false)
		return
	_mp_poll_frames += 1
	var mp := get_tree().root.get_node_or_null("MP")
	if mp != null and mp.has_signal("player_connected"):
		mp.connect("player_connected", self, "_on_mp_player_connected")
		_mp_hooked = true
		set_process(false)
	elif _mp_poll_frames > _MP_POLL_LIMIT:
		set_process(false)


# A brand-new (blank) project clears comments. A *loaded* project (p_layers != null) is NOT reset
# here — the file_system extension's open_file re-imports its saved blocks right after the base
# load (and import_state clears first), so resetting here could race that restore.
func _ev_fs_project_change(_mode: int, _args: Dictionary) -> void :
	var p_layers = _args[E.fs_project_change.p_layers]
	if p_layers == null:
		reset()


func reset() -> void :
	_cells.clear()
	_texts.clear()
	emit_signal("blocks_changed")


# --- grid helpers -----------------------------------------------------------------------------
func get_cell_size() -> int:
	return CELL_SIZE


func cell_of(board_pos: Vector2) -> Vector2:
	return Vector2(floor(board_pos.x / CELL_SIZE), floor(board_pos.y / CELL_SIZE))


func _key(cell: Vector2) -> String:
	return str(int(cell.x)) + "," + str(int(cell.y))


func _cell_from_key(k: String) -> Vector2:
	var parts := k.split(",")
	if parts.size() != 2:
		return Vector2(-1, -1)
	return Vector2(int(parts[0]), int(parts[1]))


func has_block(cell: Vector2) -> bool:
	return _cells.has(_key(cell))


# Public string key for a cell (used by the edit window to match live text updates to its group).
func key_for(cell: Vector2) -> String:
	return _key(cell)


func get_all_cells() -> Array:
	var out := []
	for k in _cells.keys():
		out.append(_cell_from_key(k))
	return out


func is_empty() -> bool:
	return _cells.empty()


# --- groups / adjacency -----------------------------------------------------------------------
# The connected component (4-neighbour) of cells reachable from `cell`, as an Array of Vector2.
func group_cells(cell: Vector2) -> Array:
	var start := _key(cell)
	if not _cells.has(start):
		return []
	var seen := {}
	var stack := [cell]
	seen[start] = true
	var group := []
	while not stack.empty():
		var c: Vector2 = stack.pop_back()
		group.append(c)
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			var n: Vector2 = c + d
			var nk := _key(n)
			if _cells.has(nk) and not seen.has(nk):
				seen[nk] = true
				stack.append(n)
	return group


# Top-most then left-most cell of a group — the stable text anchor.
func _min_cell(cells: Array) -> Vector2:
	var best: Vector2 = cells[0]
	for c in cells:
		if c.y < best.y or (c.y == best.y and c.x < best.x):
			best = c
	return best


# The anchor cell of the group `cell` belongs to, or (-1,-1) if `cell` is empty.
func anchor_of(cell: Vector2) -> Vector2:
	var group := group_cells(cell)
	if group.empty():
		return Vector2(-1, -1)
	return _min_cell(group)


func get_text(cell: Vector2) -> String:
	var anchor := anchor_of(cell)
	if anchor.x < 0:
		return ""
	return String(_texts.get(_key(anchor), ""))


# --- mutations --------------------------------------------------------------------------------
func place(cell: Vector2, broadcast: bool) -> void :
	var k := _key(cell)
	if _cells.has(k):
		return
	var old_texts := _texts.duplicate()
	_cells[k] = true
	_reconcile_texts(old_texts)
	emit_signal("blocks_changed")
	if broadcast and not _applying_remote and _live_session():
		rpc("_rpc_place", int(cell.x), int(cell.y))


func remove(cell: Vector2, broadcast: bool) -> void :
	var k := _key(cell)
	if not _cells.has(k):
		return
	var old_texts := _texts.duplicate()
	var _e = _cells.erase(k)
	_reconcile_texts(old_texts)
	emit_signal("blocks_changed")
	if broadcast and not _applying_remote and _live_session():
		rpc("_rpc_remove", int(cell.x), int(cell.y))


# Remove an entire comment group (every cell connected to `cell`).
func remove_group(cell: Vector2, broadcast: bool) -> void :
	for c in group_cells(cell):
		remove(c, broadcast)


# Set a group's text (keyed by its anchor). Streamed live to the peer as the user types.
func set_text(cell: Vector2, text: String, broadcast: bool) -> void :
	var anchor := anchor_of(cell)
	if anchor.x < 0:
		return
	var ak := _key(anchor)
	if text == "":
		var _e = _texts.erase(ak)
	else:
		_texts[ak] = text
	if broadcast and not _applying_remote and _live_session():
		rpc("_rpc_set_text", int(anchor.x), int(anchor.y), text)


# Recompute every group's anchor and keep each group's text at its anchor. When groups merge, the
# combined group keeps the distinct non-empty texts of the parts (joined by a blank line); when a
# group splits, whichever component holds the old text-bearing cell keeps it.
func _reconcile_texts(old_texts: Dictionary) -> void :
	var groups := _compute_groups()
	var new_texts := {}
	for g in groups:
		var anchor := _min_cell(g)
		var parts := []
		for c in g:
			var ck := _key(c)
			if old_texts.has(ck):
				var t: String = String(old_texts[ck])
				if t != "" and not (t in parts):
					parts.append(t)
		if not parts.empty():
			new_texts[_key(anchor)] = PoolStringArray(parts).join("\n")
	_texts = new_texts


func _compute_groups() -> Array:
	var seen := {}
	var groups := []
	for k in _cells.keys():
		if seen.has(k):
			continue
		var start := _cell_from_key(k)
		var g := group_cells(start)
		for c in g:
			seen[_key(c)] = true
		groups.append(g)
	return groups


# --- save / load (used by the file_system.gd extension) ---------------------------------------
func export_state() -> Dictionary:
	var cells := []
	for k in _cells.keys():
		var c := _cell_from_key(k)
		cells.append([int(c.x), int(c.y)])
	return {"cells": cells, "texts": _texts.duplicate()}


func import_state(data) -> void :
	_applying_remote = true
	_cells.clear()
	_texts.clear()
	if typeof(data) == TYPE_DICTIONARY:
		var cells = data.get("cells", [])
		if typeof(cells) == TYPE_ARRAY:
			for pair in cells:
				if typeof(pair) == TYPE_ARRAY and pair.size() == 2:
					_cells[_key(Vector2(int(pair[0]), int(pair[1])))] = true
		var texts = data.get("texts", {})
		if typeof(texts) == TYPE_DICTIONARY:
			for tk in texts.keys():
				_texts[String(tk)] = String(texts[tk])
	_applying_remote = false
	emit_signal("blocks_changed")


# --- multiplayer ------------------------------------------------------------------------------
func _live_session() -> bool:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null:
		return false
	if get_tree().network_peer == null:
		return false
	return bool(mp.get("is_connected")) and bool(mp.get("is_game_started"))


# Push the whole state to every peer (used when the host opens a project mid-session).
func broadcast_full_state() -> void :
	if _live_session():
		rpc("_rpc_sync_all", to_json(export_state()))


# A peer joined: if WE are the host, push the whole comment-block state so a late joiner matches.
func _on_mp_player_connected(id) -> void :
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null or not bool(mp.get("is_host")):
		return
	if get_tree().network_peer == null:
		return
	rpc_id(int(id), "_rpc_sync_all", to_json(export_state()))


remote func _rpc_place(cx: int, cy: int) -> void :
	_applying_remote = true
	place(Vector2(cx, cy), false)
	_applying_remote = false


remote func _rpc_remove(cx: int, cy: int) -> void :
	_applying_remote = true
	remove(Vector2(cx, cy), false)
	_applying_remote = false


remote func _rpc_set_text(cx: int, cy: int, text) -> void :
	_applying_remote = true
	var ak := _key(Vector2(cx, cy))
	if String(text) == "":
		var _e = _texts.erase(ak)
	else:
		_texts[ak] = String(text)
	_applying_remote = false
	emit_signal("text_changed", ak, String(text))


remote func _rpc_sync_all(state_json) -> void :
	var parsed = parse_json(String(state_json))
	import_state(parsed)
