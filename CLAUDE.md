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
mod_main.gd                     waits for Main, registers the COMMENT ink, builds the nodes below + installs the extension
scripts/comment_block_sync.gd   /root/CommentBlockSync : the data model + adjacency + MP RPCs + save API
scripts/comment_block_overlay.gd  Main/World/CommentBlockOverlay : draws blocks, hover tooltip, board draw/erase routing
scripts/comment_ink_button.gd   the palette + quick-menu "comment" ink button — a clone of the game's own button_ink.gd (indexed_color_id="COMMENT")
scripts/gui/comment_edit_window.gd  Main/CommentBlockUI/CommentEditWindow : the editor popup (note-zone TextEdit)
extensions/file_system.gd       persists blocks in the .vcb "modded" field (script extension)
```

The comment block is a **real ink**, not a separate "mode". `mod_main` first **registers a
`"COMMENT"` entry in `C.PALETTE`** (the ink "variables" every ink button reads — id, accent, name;
`STATSTYPE -1` so it's skipped by the statistics panel, and a warm-tan colour no vanilla ink uses).
`C.PALETTE` is a `const` Dictionary but GDScript 3.5 lets you mutate its **contents** at runtime, so
this adds a first-class ink without touching `vcb.pck`. The comment buttons
(`comment_ink_button.gd`) are a faithful clone of the game's own `button_ink.gd`: they carry
`indexed_color_id = "COMMENT"` and emit the same `ed_indexed_color_change` / `ed_indexed_color_pick`
events, so the game treats COMMENT exactly like DECORATION/FILLER/NONE. `mod_main` inserts a button
into the palette's **Annotation** row (`Inks/VBoxContainer/HBoxContainer6`, between `BtnFiller` and
`BtnNone`) and into the Q/A quick menu (`InkSwitchMenu/PanelContainer/HBoxContainer/HFlowContainer2`,
between `BtnFiller` and `BtnNone`), joined to each bar's ink `ButtonGroup` and appended to the quick
menu's `buttons` list. Wiring is retried across frames (the docked circuit editor + the quick menu's
`buttons` list build a little after `Main` appears); if it ever times out, `mod_main._diagnose()`
logs which of `Main`/`Inks`/`InkSwitchMenu`/`qm.buttons` was still missing. There is **no toolbar
toggle button**.

**Why runtime injection (not a scene edit):** the launcher's Mod Loader loads each mod zip with
`ProjectSettings.load_resource_pack(path, false)` — `replace_files = false` — so a mod **cannot**
override a vanilla resource such as `circuit_editor.tscn`. Adding the button (and the palette entry)
at runtime is the only mechanism available; it's the same technique the Board Size and Improvements
mods use to add their own controls to the circuit-editor panel.

### 2.1 Data model + grouping (`comment_block_sync.gd`)
- Blocks snap to a grid of `CELL_SIZE` (8) board pixels. `_cells = {"cx,cy": true}`.
- **Adjacent blocks (4-neighbour) form one group** = a connected component (`group_cells`, flood
  fill). Each group's text lives at its **anchor** = top-most then left-most cell
  (`anchor_of`/`_min_cell`). `_texts = {"<anchor cx,cy>": text}` — one entry per non-empty group.
- `place`/`remove` first snapshot the text of **every occupied cell** (`_snapshot_cell_texts`: each
  cell of a non-empty group → that group's text), then mutate `_cells`, then `_reconcile_texts`
  re-homes each group's text at its (possibly new) anchor by inheriting the text carried by ANY of
  its cells in that snapshot. So a comment follows its group as it grows/shrinks/re-anchors and is
  **only lost when the group's LAST block is removed** — deleting the top-left/anchor cell no longer
  drops it. Merging joins distinct non-empty texts with a newline; splitting keeps the text on each
  surviving piece. `set_text` writes at the anchor. `remove_group` clears a whole group.
- Emits `blocks_changed` (overlay redraws) and `text_changed(anchor_key, text)` (open popup on a
  peer updates live).

### 2.2 Overlay (`comment_block_overlay.gd`, a `Node2D` under `Main/World`)
- Sibling of `CursorBoard`, so it shares board-pixel space and pans/zooms with the camera (the
  cursor being visible on top of the board proves World `Node2D` children draw above it).
- **Drawing (`_draw`)**: two layers. (1) A warm-orange fill+edge per cell, drawn only where it's
  useful and **faded**: every cell at `_all_alpha` (→1 while the comment ink is active, so you can
  see all zones while placing), plus the hovered zone's cells at `_hover_alpha` (→1 while hovering a
  zone with any *other* tool). Cells with ~0 alpha are skipped. (2) The **"T" marker** (the stock
  `text_symbol.png` glyph, `T_ICON_PATH`, tinted `T_TINT`) drawn at each group's **anchor** (its
  top-left cell), **always** — so a comment reads as an annotation without the orange covering the
  board. Falls back to the old quote glyph if the texture is missing. `_process` eases `_all_alpha`
  / `_hover_alpha` toward their targets (`_approach`, `FADE_SPEED` ≈ 0.12 s) and `update()`s while
  they move (Node2D otherwise retains the last frame, so a steady state costs no redraws). The
  hovered zone's cell set (`_hover_cells`, keyed like the sync) is recomputed only when the hovered
  **anchor** changes.
- **Hover tooltip**: polled in `_process` from `get_global_mouse_position()` (board coords) gated
  by `_is_world_frame` (from `E.ui_context_change`, `C.CONTEXT.WORLD_FRAME`). The tooltip is a
  `Label` in a `PanelContainer` on its own `CanvasLayer` (screen space), positioned at
  `get_viewport().get_mouse_position() + (18,20)` each frame, faded with a `Tween` on `modulate`
  (0.12 s `TRANS_SINE`) — the same fade idiom the stock UI uses (`notes.gd`,
  `flux_btn_checkbox.gd`). Works in edit AND sim.
- **Selecting the comment ink** (drawing comments): because the comment buttons are real inks, the
  overlay keys its state off the **authoritative `ed_indexed_color_change` event** (not off the
  buttons' `toggled` — that turned out fragile). `_ev_ed_indexed_color_change`: id `== "COMMENT"` →
  `_enter()`; any other id → record it as the "previous ink" and, if active, `_leave()`. The two
  comment buttons (palette + quick menu) stay in sync automatically the way native inks do — each
  responds to `ed_indexed_color_pick("COMMENT")` by pressing itself, and each bar's `ButtonGroup`
  unpresses the rest. They still `register_button` with the overlay, but only so it can disable them
  during simulation. On `_enter` the overlay remembers the previous tool and holds the editor tool
  at `NONE` **by writing `editor.editor_tool` directly, WITHOUT emitting `ed_tool_change_emitted`**.
  That suppresses only *local* painting (the editor's `_ev_mi_mouse_input_on_board` has no branch for
  `NONE`) while `circuit_editor.gd` / `footer.gd` — which react to the tool-change **event**, not the
  var — never hear about it, so **the toolbar/side panel stay put** showing the previous tool with
  the comment ink highlighted, like any ink. (The old code emitted the event, which blanked the
  toolbar — that was the bug.) Multiplayer remote drawing is unaffected: the MP `editor.gd`
  extension applies remote strokes with the tool carried in the event **payload**, not the local
  `editor_tool`. `_leave(restore_tool, repick_ink)` covers every exit and always **repairs
  `editor.last_tool`** to the real previous tool (while the tool was pinned to `NONE`, entering a
  sim or picking a tool copied `NONE` into `last_tool`; leaving a sim re-applies `last_tool`, so an
  un-repaired `NONE` would blank the toolbar after the sim). It restores `editor.editor_tool` to the
  previous tool for every exit **except** a tool pick (there the picked tool must stay). Picking
  another **ink** → `_leave(true, false)`; picking a real **tool** → `_leave(false, true)` (keep the
  tool, re-pick the previous ink); **simulation** start → `_leave(true, true)` + disables the
  buttons. `_prev_ink_id` is seeded from the editor's current ink in `_ready` so the first pick can
  always be handed back.
- **Board draw/erase** (via `E.mi_mouse_input_on_board`, only while the comment ink is active + edit
  mode + inside `C.CIRCUIT.RECT`): it draws like a trace — **left** click/drag `place`s blocks
  (drag tracked with `_drag_place`); a plain left click on an **existing** block opens the popup
  instead of starting a drag; **right** click/drag `remove`s blocks (`_drag_erase`). Drag flags
  reset on release / leave.

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
- **`Editor.TOOL.NONE` while the comment ink is active** (set on `editor.editor_tool` **directly**,
  not via `ed_tool_change_emitted`): chosen because the editor's mouse handler has no branch for it
  (so nothing paints locally) — this lets the mod place blocks without the normal tools drawing,
  while the toolbar (which only reacts to the tool-change *event*) stays put. Verify no other path
  treats `NONE` specially, and that `_leave` correctly restores `editor_tool`/`last_tool` (see
  §2.2). It's MP-safe because the MP `editor.gd` extension applies **remote** strokes with the tool
  from the event payload, not `editor_tool`; the direct write only gates *local* painting. (We
  still can't cleanly extend `editor.gd` here: the Multiplayer mod reproduces
  `_ev_mi_mouse_input_on_board` verbatim, so chaining a second override is fragile — hence pinning
  the tool var instead of adding a paint guard.)
- **Look is a marker + a hover/active fill**, not a full texture. On the board, each zone shows the
  stock white `text_symbol.png` "T" glyph (tinted `T_TINT`) at its anchor cell always, plus the warm
  fill (`BLOCK_FILL`/`BLOCK_EDGE`) only while the comment ink is active (all zones) or on the hovered
  zone (faded, `FADE_SPEED`). The palette/quick-menu button uses the same white `text_symbol.png`
  glyph tinted by a `FluxModTextureButton` accent read from the registered `C.PALETTE["COMMENT"].ON`
  (falling back to `COMMENT_ACCENT` if the entry is somehow missing), matching native ink buttons.
  For a fuller custom texture, set it as `comment_ink_button`'s `texture_normal` and swap the overlay
  `_draw` marker/fill; tune `CELL_SIZE`/`T_TINT`.
- **Palette/quick-menu placement**: the comment ink is inserted into the palette's `HBoxContainer6`
  ("Annotation" row) between `BtnFiller`/`BtnNone`, and into the quick menu's `HFlowContainer2`
  between `BtnFiller`/`BtnNone`, joined to each bar's `ButtonGroup` (read off `BtnNone` / the menu's
  `buttons[0]`) and appended to `qm.buttons`. Wiring retries across frames until both bars exist
  (docking builds the circuit editor, and the menu fills `buttons` in its `_ready`, a little after
  `Main` appears); a timeout logs `_diagnose()` (which of Main/Inks/InkSwitchMenu/qm.buttons was
  missing). Enter/leave is driven by `ed_indexed_color_change`, so the "no ink highlighted after
  leaving comment" quirk is handled by `_leave(..., repick_ink=true)` on non-ink exits.
- **`C.PALETTE["COMMENT"]` registration**: relies on GDScript 3.5 allowing mutation of a `const`
  Dictionary's contents — but it must be done through a **local reference**
  (`var pal = C.PALETTE; pal["COMMENT"] = {…}`), NOT `C.PALETTE["COMMENT"] = {…}` directly. Writing
  a nested key straight through the singleton makes GDScript 3.5 emit a *write-back* of the whole
  dict to the `const PALETTE` property, which fails at runtime with `Invalid set index 'PALETTE'`
  (spammed every frame until wiring finishes). Dictionaries are references, so the local mutates the
  same dict the singleton holds. It's a first-class ink but is never actually painted (the overlay
  holds `TOOL.NONE`), so the engine never sees it. The colour (`e1be83`) is unique, so the
  eyedropper (`tool_color_picker.gd`) and mouse-over readout (`mouse_over_label.gd`) never mis-match
  it, and `STATSTYPE -1` keeps it out of `card_statistics.gd`. If a future engine build makes const
  dicts read-only, the button falls back to `COMMENT_ACCENT` and still works.
- **MP**: both peers need this mod. Text streaming + place/remove + late-join sync are implemented;
  a same-instant place-and-type race on the exact same new group is not specially resolved (last
  writer wins, self-healing on the next edit / re-open).
- Everything here is **UNVERIFIED in-engine** (no Godot in CI). See the test recipe in §5.

## 4. Engine / GDScript constraints

- **Godot 3.5.1**, GDScript 3.5 semantics — **not** Godot 4. No Godot-4 syntax.
- **Never use an RPC keyword as an identifier.** `remote`, `master`, `puppet`, `remotesync`,
  `mastersync`, `puppetsync`, `sync`, `slave` are reserved GDScript tokens. Naming a variable/param
  `sync` (e.g. `var sync := ...`) is a **compile error that makes the whole script — and therefore
  the whole mod — fail to load silently** (this is exactly why the comment block didn't appear until
  v1.2.1: `mod_main.gd` and `file_system.gd` both had `var sync`). Use `sync_node` etc. You can
  parse-check locally with `gdtoolkit` (build the parser fresh with `Parser().disable_grammar_caching()`
  to dodge its stale pickled grammar).
- **`:=` type inference is a loaded gun — it caused the "nothing appears" bug.** In Godot 3.5,
  `var x := <expr>` is a **fatal parse error** ("The assigned value doesn't have a set type; the
  variable type can't be inferred") whenever the compiler can't statically determine the RHS type —
  most commonly a method call on a `Node`-typed variable (e.g. `var cell := _sync.cell_of(pos)`
  where `_sync: Node`), a call to a `void` function, or `var x := null`. **gdtoolkit does NOT catch
  this** (it only checks grammar). Such an error makes the whole script fail to compile; then
  `_new_script()`'s `scr.new()` returns null, `_build_core()` returns false forever, and the mod
  shows **nothing at all** — no overlay, no tooltip, no palette/quick-menu buttons. This is exactly
  why the comment block never appeared through v1.3.0 (`comment_block_overlay.gd` had two
  `var cell := _sync.cell_of(...)` lines). Fix: give the var an explicit type
  (`var cell: Vector2 = _sync.cell_of(...)`) or drop inference (`var x = ...`). Prefer `:=` only when
  the RHS type is obvious to the compiler (literals, typed-return built-ins, `String(...)`, etc.).
- **Compile-check with a real Godot 3.5.1, not just gdtoolkit.** gdtoolkit misses identifier
  resolution and `:=` inference errors. Definitive local check (this is how the v1.3.1 bug was
  found): download `Godot_v3.5.1-stable_linux_headless.64`, make a throwaway project with stub
  autoloads (`C`, `E`) and stub `class_name`s (`Editor`, `ModLoaderLog`, `ModLoaderMod`) providing
  the symbols the mod uses, then in a main scene `_ready` do `load("res://…/script.gd").can_instance()`
  for each mod script — `can_instance()` is `true` only if the script fully compiled. Autoloads are
  only registered when the project actually runs (not with `--check-only --script`), so run the
  project headless rather than checking single scripts in isolation.
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
- Test recipe (in-engine): enable modding + drop the zip, launch. Confirm the **comment** ink
  appears in the palette's Annotation row (between Filler and None) AND in the Q/A quick menu
  (between Filler and None). Select it — **the editor toolbar/side panel must NOT disappear** (it
  keeps showing the previous tool, with the comment ink highlighted) — and **every** comment zone
  shows the orange fill. **left-drag** to paint a few blocks; **left-click** an existing block →
  type → Enter; hover to read (tooltip follows the mouse + fades). Place blocks adjacent → confirm
  they share one comment; **right-click / right-drag** to erase. Pick another ink or tool → comment
  deselects, the orange fill disappears, and **each zone shows just the "T" marker**; hovering a
  zone fades its orange overlay in/out. Save the `.vcb`, reopen → comments persist; a comment-free
  board saves clean. Start a simulation → hover still shows text, drawing is disabled; **stop the
  sim → the toolbar comes back** (not blank). With the Multiplayer mod: on host + joiner, draw/type
  on one → the other sees blocks appear and text stream in; while one player has the comment ink
  selected, the **other's normal trace drawing still applies** on both boards; a late joiner
  receives existing comments.
```
