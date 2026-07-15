# CLAUDE.md — agent context for `vcb-comment-block`

Read this first. Dense on purpose, for an AI coding agent. If it conflicts with the code, the
code wins — but verify before assuming this file is stale.

---

## 0. What this repo is

- A **runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod** for
  **Virtual Circuit Board** that adds an **editor-only comment block**. Pure GDScript; loads at
  runtime from the game's `mods/` folder and **never replaces `vcb.pck`**.
- Runs on the **original, closed-source VCB engine** (Godot 3.5.1). The native `Transistor*`
  classes are provided by the game at runtime; the "unknown class" editor warning is EXPECTED.
- **Independent of, but compatible with**, the other VCB mods (Multiplayer, Board Size, Mod Menu).

## 1. The core idea: comment blocks are NOT part of the circuit

VCB's board is four image layers whose pixels ARE the circuit; the sim compiles them every run. A
comment block must **never** touch those layers, so it's kept entirely in a **mod-owned overlay +
data model** and drawn on top of the board. The simulation engine never sees it — that's the whole
point of "editor-only". Text is arbitrary strings, which also can't live in a pixel layer, so it's
stored in the mod's own data and persisted in the `.vcb`'s `modded` field.

## 2. Architecture (4 pieces + 1 extension)

```
mod_main.gd                     waits for Main, then builds the nodes below + installs the extension
scripts/comment_block_sync.gd   /root/CommentBlockSync : the data model + adjacency + MP RPCs + save API
scripts/comment_block_overlay.gd  Main/World/CommentBlockOverlay : draws blocks, hover tooltip, click routing, comment mode
scripts/comment_ink_button.gd   the palette + quick-menu "comment" entry (a toggle TextureButton)
scripts/gui/comment_edit_window.gd  Main/CommentBlockUI/CommentEditWindow : the editor popup (note-zone TextEdit)
extensions/file_system.gd       persists blocks in the .vcb "modded" field (script extension)
```

### 2.1 Data model + grouping (`comment_block_sync.gd`)
- Blocks snap to a grid of `CELL_SIZE` (8) board pixels. `_cells = {"cx,cy": true}`.
- **Adjacent blocks (4-neighbour) form one group** = a connected component (`group_cells`, flood
  fill). Each group's text lives at its **anchor** = top-most then left-most cell
  (`anchor_of`/`_min_cell`). `_texts = {"<anchor cx,cy>": text}` — one entry per non-empty group.
- `place`/`remove` mutate `_cells`, then `_reconcile_texts` recomputes groups and keeps each
  group's text at its anchor (merging distinct texts on join; the text-bearing component keeps it
  on split). `set_text` writes at the anchor. `remove_group` clears a whole group.
- Emits `blocks_changed` (overlay redraws) and `text_changed(anchor_key, text)` (open popup on a
  peer updates live).

### 2.2 Overlay (`comment_block_overlay.gd`, a `Node2D` under `Main/World`)
- Sibling of `CursorBoard`, so it shares board-pixel space and pans/zooms with the camera (the
  cursor being visible on top of the board proves World `Node2D` children draw above it). `_draw`
  fills each cell + a quote glyph on anchors.
- **Hover tooltip**: polled in `_process` from `get_global_mouse_position()` (board coords) gated
  by `_is_world_frame` (from `E.ui_context_change`, `C.CONTEXT.WORLD_FRAME`). The tooltip is a
  `Label` in a `PanelContainer` on its own `CanvasLayer` (screen space), positioned at
  `get_viewport().get_mouse_position() + (18,20)` each frame, faded with a `Tween` on `modulate`
  (0.12 s `TRANS_SINE`) — the same fade idiom the stock UI uses (`notes.gd`,
  `flux_btn_checkbox.gd`). Works in edit AND sim.
- **Comment mode + selection**: comment mode is entered by selecting the comment "ink" from any of
  three entry points, all registered with the overlay via `register_button` and kept in sync by
  `_sync_buttons` (block-signalled): (1) a **Comment** toolbar toggle in `FileControls`; (2) a
  **palette** entry — a `comment_ink_button` added as a new row in the ink bar
  (`Inks/VBoxContainer`), joined to the inks' `ButtonGroup` (read off an existing ink button) so it
  selects/deselects like an ink; (3) a **quick-menu** entry — a `comment_ink_button` added to
  `Interface/GUI/InkSwitchMenu`'s `HFlowContainer`, joined to that menu's runtime `ButtonGroup` and
  appended to its `buttons` list so it's hover-selectable (it provides the `public_unhover` /
  `public_enable_ink_switch_usage` methods the menu calls). Entering **requests editor tool `NONE`**
  (`ed_tool_change_emitted`) so the normal tools don't draw; the editor's `_ev_mi_mouse_input_on_board`
  has no branch for `NONE`. Leaving happens when a real tool is picked (`ed_tool_change_emitted`
  false, tool != NONE), when an **ink** is picked (`_ev_ed_indexed_color_change`), on simulation
  start, or by toggling a comment button off; the previous tool is restored.
- **Board clicks** (via `E.mi_mouse_input_on_board`, only in comment mode + edit mode + inside
  `C.CIRCUIT.RECT`, on `just_pressed`): left on empty cell → `place`; left on a block → open the
  popup; right on a block → `remove`.

### 2.3 Editor popup (`comment_edit_window.gd`, a themed `WindowDialog`)
- Same window kind/theme as the Multiplayer / Board Size dialogs. Holds a multi-line `TextEdit`
  (note-zone style). `open_for(anchor)` loads the group's text. `text_changed` **streams** every
  keystroke via `sync.set_text(anchor, text, true)` (so it's stored immediately and mirrored to the
  peer). `_input` catches **Enter** (save+close) vs **Shift+Enter** (newline). Reflects a peer's
  live edits via `sync.text_changed` (guarded not to yank the caret while focused).

### 2.4 Multiplayer (mirrors the Board Size mod's pattern)
- `CommentBlockSync` rides the Multiplayer mod's ENet peer (never opens its own). `_live_session()`
  = MP autoload present + `network_peer` + `is_connected` + `is_game_started`, all via
  `get_node_or_null`/`Object.get` so it works with MP absent.
- `remote func _rpc_place/_rpc_remove/_rpc_set_text` mirror edits (guarded by `_applying_remote`).
  Text is streamed live. `_on_mp_player_connected` (host) pushes the whole state to a late joiner
  via `rpc_id(id, "_rpc_sync_all", to_json(export_state()))`. The MP autoload is found by polling
  in `_process` (load order isn't fixed), then its `player_connected` signal is hooked.

### 2.5 Persistence (`extensions/file_system.gd`)
- Shared **`modded`** convention (same as the Board Size mod): `save_file` merges
  `modded["npopescu-VCBCommentBlock"] = {cells, texts}` (dropping it when there are no blocks, so a
  comment-free board stays vanilla-openable); `open_file` restores after the base loads, and
  broadcasts the loaded state to peers in a live session. Both this mod and the Board Size mod
  extend `file_system.gd`; they coexist because each only touches its own key and calls the base.

## 3. Known limitations / assumptions to verify in-engine

- **Overlay z-order**: assumed World `Node2D` children render above the board (as the brush cursor
  does). If comment blocks render *behind* the board, adjust the overlay's `z_index`/parent.
- **`Editor.TOOL.NONE` as the comment-mode tool**: chosen because the editor's mouse handler has no
  branch for it (so nothing paints). Verify no other path treats `NONE` specially.
- **Default look is a colour + glyph**, not a texture. When a real texture exists, use it for the
  toolbar `btn.icon`, the `comment_ink_button` textures (`_make_texture`), and swap the overlay
  `_draw` rect for a `draw_texture_rect`; tune `CELL_SIZE`.
- **Palette/quick-menu integration is UNVERIFIED and the most fragile part.** Assumptions to check:
  the ink bar is at `Inks/VBoxContainer` and its ink buttons share one `ButtonGroup`; the quick
  menu is at `Interface/GUI/InkSwitchMenu` with buttons under `PanelContainer/HBoxContainer/
  HFlowContainer` and a public `buttons` array + runtime `ButtonGroup`; appending to `qm.buttons`
  after its `_ready` makes the entry hover-selectable. **Known cosmetic quirk:** because the comment
  entry shares the inks' `ButtonGroup`, leaving comment mode *without* picking an ink (e.g. clicking
  the comment button off, or picking a tool) can leave the ink grid with **no ink visually
  selected** — the last ink is still the active `indexed_color_id`, so drawing still works; it's
  only the highlight that's missing until you click an ink. (Fix idea for later: remember the ink on
  enter and re-`ed_indexed_color_pick` it on non-ink exits.)
- **MP**: both peers need this mod. Text streaming + place/remove + late-join sync are implemented;
  a same-instant place-and-type race on the exact same new group is not specially resolved (last
  writer wins, self-healing on the next edit / re-open).
- Everything here is **UNVERIFIED in-engine** (no Godot in CI). See the test recipe in §5.

## 4. Engine / GDScript constraints

- **Godot 3.5.1**, GDScript 3.5 semantics — **not** Godot 4. No Godot-4 syntax.
- **Tabs, not spaces**, in every `.gd`. Quick check: `grep -nP '^\t* +\S' <file>` must be empty
  for lines you add.
- `C` and `E` are the game's autoloads (always present); `Editor` is a `class_name`. `MP` /
  `MPDrawSync` belong to the Multiplayer mod and may be absent — always `get_node_or_null`.
- You **cannot run or parse-check GDScript** in CI here — review carefully; logs go to the game's
  `user://ModLoader.log`.

## 5. Git / PR workflow for agents

- Branch from `origin/main` (`git fetch origin main` first).
- **Branch names MUST start with `claude/` and END WITH the current session id**, or `git push`
  fails with HTTP 403. Example: `claude/<topic>-<sessionid>`.
- Commits are auto-signed (ssh). Don't disable signing/hooks.
- Open PRs against `main`; squash-merge. **One PR per change** (no duplicate branches).
- Test recipe (in-engine): enable modding + drop the zip, launch. Click **Comment**; place a few
  blocks; click one → type → Enter; hover to read (tooltip follows the mouse + fades). Place blocks
  adjacent → confirm they share one comment; right-click to delete. Save the `.vcb`, reopen →
  comments persist; a comment-free board saves clean. Start a simulation → hover still shows text,
  editing is disabled. With the Multiplayer mod: on host + joiner, place/type on one → the other
  sees blocks appear and text stream in; a late joiner receives existing comments.
```
