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
#   _cells        : { "cx,cy": true }              every occupied cell
#   _texts        : { "<anchor cx,cy>": "text" }   one entry per non-empty group, keyed by its anchor
#   _authors      : { "<anchor cx,cy>": peer_id }  who wrote each non-empty group (0 = solo/unknown)
#   _author_names : { "<anchor cx,cy>": "name" }   the author's DISPLAY NAME, snapshotted at write
#                                                  time so it still shows when the file is later
#                                                  opened solo (peer ids are per-session; names are
#                                                  what a reader actually wants).
#
# Two DIFFERENT written comments never fuse or touch: a placement that would connect two or more
# distinct non-empty groups is refused (see place()). You can only grow/merge using EMPTY blocks, so
# an empty new comment may still merge into a single existing written comment.
#
# Multiplayer
# -----------
# When the VCB Multiplayer mod has a live peer, placements / removals / live text edits are mirrored
# over its ENet peer (this mod never opens its own), and the host pushes the whole state to a late
# joiner. Each peer also broadcasts a light "presence" (its comment-mode brush size + hovered cell)
# so the other side can draw that player's comment placement preview in their multiplayer colour.
# All MP calls are guarded by _live_session() via get_node_or_null/Object.get, so the mod works fine
# with the Multiplayer mod absent.

const CELL_SIZE := 4

var _cells := {}
var _texts := {}
# anchor key -> author peer id (who wrote the note). 0 = solo / unknown (default colour, no name).
var _authors := {}
# anchor key -> author display name, snapshotted when the note is written (so it survives to a later
# solo open, where peer ids no longer resolve to people).
var _author_names := {}

var _applying_remote := false

# Remote comment-mode presence, peer id -> { "brush": int, "cell": Vector2 } (only present while that
# peer is actively drawing comments). The overlay draws a placement preview for each, in the peer's
# multiplayer colour. Never persisted.
var _remote_presence := {}

# Multiplayer hook (mod load order isn't fixed, so poll for the MP autoload, then connect once).
var _mp_hooked := false
var _mp_poll_frames := 0
const _MP_POLL_LIMIT := 3600  # ~1 min at 60 fps, then give up (MP mod simply isn't installed)

signal blocks_changed
signal text_changed(anchor_key, text)
signal presence_changed


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
		if mp.has_signal("player_disconnected"):
			mp.connect("player_disconnected", self, "_on_mp_player_disconnected")
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
	_authors.clear()
	_author_names.clear()
	_remote_presence.clear()
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


# The author (peer id) of the note on `cell`'s group, or 0 when solo / unknown.
func get_author(cell: Vector2) -> int:
	var anchor := anchor_of(cell)
	if anchor.x < 0:
		return 0
	return int(_authors.get(_key(anchor), 0))


# The author's saved display name for `cell`'s group ("" when unknown / none). Persisted, so it
# still resolves after a solo re-open where the peer id no longer maps to a person.
func get_author_name(cell: Vector2) -> String:
	var anchor := anchor_of(cell)
	if anchor.x < 0:
		return ""
	return String(_author_names.get(_key(anchor), ""))


# Our own author id: our multiplayer peer id in a session, else 0 (solo → default colour, no name).
func _current_author() -> int:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp != null and int(mp.get("my_id")) != 0:
		return int(mp.get("my_id"))
	return 0


# Our own display name, for stamping onto notes we write (so it persists into the file). "" solo.
func _current_author_name() -> String:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null:
		return ""
	var mine: int = int(mp.get("my_id"))
	if mine == 0:
		return ""
	if mp.has_method("get_player_name"):
		return String(mp.get_player_name(mine))
	var pn = mp.get("player_name")
	if pn != null:
		return String(pn)
	return ""


# True if placing `cell` would connect two or more DISTINCT non-empty comment groups. Such a
# placement is refused (see place()) so two written comments never fuse or touch — you can only
# grow/merge using EMPTY blocks (an empty new comment may still merge into ONE written comment).
func _would_bridge_nonempty(cell: Vector2) -> bool:
	var anchors := []
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		var n: Vector2 = cell + d
		var nk := _key(n)
		if not _cells.has(nk):
			continue
		var anchor := anchor_of(n)
		var ak := _key(anchor)
		if ak in anchors:
			continue
		if String(_texts.get(ak, "")) != "":
			anchors.append(ak)
	return anchors.size() >= 2


# --- mutations --------------------------------------------------------------------------------
func place(cell: Vector2, broadcast: bool) -> void :
	var k := _key(cell)
	if _cells.has(k):
		return
	# Refuse a placement that would bridge two written comments (keeps distinct non-empty comments
	# from fusing or touching). Applied on both peers identically, so boards stay consistent.
	if _would_bridge_nonempty(cell):
		return
	var old_cell_texts := _snapshot_cell_texts()
	var old_cell_authors := _snapshot_cell_authors()
	var old_cell_author_names := _snapshot_cell_author_names()
	_cells[k] = true
	_reconcile_texts(old_cell_texts, old_cell_authors, old_cell_author_names)
	emit_signal("blocks_changed")
	if broadcast and not _applying_remote and _live_session():
		rpc("_rpc_place", int(cell.x), int(cell.y))


func remove(cell: Vector2, broadcast: bool) -> void :
	var k := _key(cell)
	if not _cells.has(k):
		return
	var old_cell_texts := _snapshot_cell_texts()
	var old_cell_authors := _snapshot_cell_authors()
	var old_cell_author_names := _snapshot_cell_author_names()
	var _e = _cells.erase(k)
	_reconcile_texts(old_cell_texts, old_cell_authors, old_cell_author_names)
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
	var author := _current_author()
	var author_name := _current_author_name()
	if text == "":
		var _e = _texts.erase(ak)
		var _e2 = _authors.erase(ak)
		var _e3 = _author_names.erase(ak)
	else:
		_texts[ak] = text
		_authors[ak] = author
		_author_names[ak] = author_name
	if broadcast and not _applying_remote and _live_session():
		rpc("_rpc_set_text", int(anchor.x), int(anchor.y), text, author, author_name)


# Snapshot the CURRENT text of every occupied cell (each cell of a non-empty group maps to that
# group's text), taken BEFORE a place/remove mutates `_cells`. `_reconcile_texts` uses it to carry
# each group's text onto whatever cells survive — so a comment is only lost when its LAST block is
# removed, not when the specific anchor (top-left) cell happens to be the one deleted.
func _snapshot_cell_texts() -> Dictionary:
	var out := {}
	for g in _compute_groups():
		var t := String(_texts.get(_key(_min_cell(g)), ""))
		if t != "":
			for c in g:
				out[_key(c)] = t
	return out


# Parallel to _snapshot_cell_texts: each cell of a non-empty group -> that group's author id.
func _snapshot_cell_authors() -> Dictionary:
	var out := {}
	for g in _compute_groups():
		var ak := _key(_min_cell(g))
		var t := String(_texts.get(ak, ""))
		if t != "":
			var a: int = int(_authors.get(ak, 0))
			for c in g:
				out[_key(c)] = a
	return out


# Parallel to _snapshot_cell_texts: each cell of a non-empty group -> that group's author name.
func _snapshot_cell_author_names() -> Dictionary:
	var out := {}
	for g in _compute_groups():
		var ak := _key(_min_cell(g))
		var t := String(_texts.get(ak, ""))
		if t != "":
			var nm := String(_author_names.get(ak, ""))
			for c in g:
				out[_key(c)] = nm
	return out


# Recompute every group's anchor and re-home its text there. Each group inherits the text carried
# by any of its cells in `old_cell_texts` (the pre-mutation per-cell snapshot): so text follows the
# group as it grows/shrinks/re-anchors, and survives deleting the old anchor cell. When groups merge
# their distinct non-empty texts are joined by a newline; when a group splits, each surviving piece
# keeps the text (the comment only disappears once every block of the group is gone). Author id +
# name ride along, taken from the first contributing cell.
func _reconcile_texts(old_cell_texts: Dictionary, old_cell_authors: Dictionary = {}, old_cell_author_names: Dictionary = {}) -> void :
	var groups := _compute_groups()
	var new_texts := {}
	var new_authors := {}
	var new_author_names := {}
	for g in groups:
		var anchor := _min_cell(g)
		var parts := []
		var author: int = 0
		var author_name := ""
		for c in g:
			var ck := _key(c)
			if old_cell_texts.has(ck):
				var t: String = String(old_cell_texts[ck])
				if t != "" and not (t in parts):
					parts.append(t)
					# The merged note keeps the first contributing cell's author + name.
					if author == 0 and old_cell_authors.has(ck):
						author = int(old_cell_authors[ck])
					if author_name == "" and old_cell_author_names.has(ck):
						author_name = String(old_cell_author_names[ck])
		if not parts.empty():
			var ak := _key(anchor)
			new_texts[ak] = PoolStringArray(parts).join("\n")
			new_authors[ak] = author
			new_author_names[ak] = author_name
	_texts = new_texts
	_authors = new_authors
	_author_names = new_author_names


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


# Every comment group (connected component), as an Array of Arrays of Vector2. Used by the overlay
# to draw one "T" marker centered on each group.
func get_groups() -> Array:
	return _compute_groups()


# --- save / load (used by the file_system.gd extension) ---------------------------------------
func export_state() -> Dictionary:
	var cells := []
	for k in _cells.keys():
		var c := _cell_from_key(k)
		cells.append([int(c.x), int(c.y)])
	return {
		"v": 2,
		"cell": CELL_SIZE,
		"cells": cells,
		"texts": _texts.duplicate(),
		"authors": _authors.duplicate(),
		"author_names": _author_names.duplicate(),
	}


func import_state(data) -> void :
	_applying_remote = true
	_cells.clear()
	_texts.clear()
	_authors.clear()
	_author_names.clear()
	if typeof(data) == TYPE_DICTIONARY:
		# Files saved before the grid was halved (v1, no "v" key) stored cells on the old 8px grid.
		# Scale them onto the 4px grid: each old cell becomes a 2x2 block and each text key moves to
		# that block's top-left (its new anchor). New files (v2) load as-is.
		var version: int = int(data.get("v", 1))
		var scale: int = 2 if version < 2 else 1
		var cells = data.get("cells", [])
		if typeof(cells) == TYPE_ARRAY:
			for pair in cells:
				if typeof(pair) == TYPE_ARRAY and pair.size() == 2:
					var bx: int = int(pair[0]) * scale
					var by: int = int(pair[1]) * scale
					for dx in range(scale):
						for dy in range(scale):
							_cells[_key(Vector2(bx + dx, by + dy))] = true
		var texts = data.get("texts", {})
		if typeof(texts) == TYPE_DICTIONARY:
			for tk in texts.keys():
				_texts[_remap_key(String(tk), scale)] = String(texts[tk])
		var authors = data.get("authors", {})
		if typeof(authors) == TYPE_DICTIONARY:
			for tk in authors.keys():
				_authors[_remap_key(String(tk), scale)] = int(authors[tk])
		var author_names = data.get("author_names", {})
		if typeof(author_names) == TYPE_DICTIONARY:
			for tk in author_names.keys():
				_author_names[_remap_key(String(tk), scale)] = String(author_names[tk])
	_applying_remote = false
	emit_signal("blocks_changed")


# Remap a saved anchor key onto the current grid (v1 8px cells → v2 4px cells scale by 2).
func _remap_key(k: String, scale: int) -> String:
	if scale == 1:
		return k
	var oc := _cell_from_key(k)
	return _key(Vector2(int(oc.x) * scale, int(oc.y) * scale))


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


# A peer left: drop any comment-mode presence preview we were drawing for them.
func _on_mp_player_disconnected(id) -> void :
	if _remote_presence.has(int(id)):
		var _e = _remote_presence.erase(int(id))
		emit_signal("presence_changed")


# --- comment-mode presence (so a peer's placement preview shows in their colour) ---------------
# Broadcast whether WE are actively drawing comments, and where (brush size + hovered cell). The
# overlay calls this on change. When `active` is false the peer's preview is cleared.
func broadcast_presence(active: bool, brush: int, cell: Vector2) -> void :
	if not _live_session():
		return
	if active:
		rpc("_rpc_presence", true, int(brush), int(cell.x), int(cell.y))
	else:
		rpc("_rpc_presence", false, int(brush), 0, 0)


remote func _rpc_presence(active, brush, cx, cy) -> void :
	var sender: int = get_tree().get_rpc_sender_id()
	if bool(active):
		_remote_presence[sender] = {"brush": int(brush), "cell": Vector2(int(cx), int(cy))}
	else:
		var _e = _remote_presence.erase(sender)
	emit_signal("presence_changed")


# Peer id -> { "brush": int, "cell": Vector2 } for every peer currently drawing comments.
func get_remote_presence() -> Dictionary:
	return _remote_presence


remote func _rpc_place(cx: int, cy: int) -> void :
	_applying_remote = true
	place(Vector2(cx, cy), false)
	_applying_remote = false


remote func _rpc_remove(cx: int, cy: int) -> void :
	_applying_remote = true
	remove(Vector2(cx, cy), false)
	_applying_remote = false


remote func _rpc_set_text(cx: int, cy: int, text, author = 0, author_name = "") -> void :
	_applying_remote = true
	var ak := _key(Vector2(cx, cy))
	if String(text) == "":
		var _e = _texts.erase(ak)
		var _e2 = _authors.erase(ak)
		var _e3 = _author_names.erase(ak)
	else:
		_texts[ak] = String(text)
		_authors[ak] = int(author)
		_author_names[ak] = String(author_name)
	_applying_remote = false
	emit_signal("text_changed", ak, String(text))


remote func _rpc_sync_all(state_json) -> void :
	var parsed = parse_json(String(state_json))
	import_state(parsed)
