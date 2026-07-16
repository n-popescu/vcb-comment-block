# VCB Comment Block

A runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod for
[Virtual Circuit Board](https://store.steampowered.com/app/1885690/Virtual_Circuit_Board/) that
adds an **editor-only comment block** — a block you place on the board to annotate your circuit.

- **It's just another ink.** The comment block sits in the palette's **Annotation** row (between
  Filler and None) and in the **Q/A quick menu** (between Filler and None). Pick it like any ink
  and **draw** comment blocks with the mouse — left-click or drag to place, right-click or drag to
  erase. Selecting it **keeps the whole editor toolbar in place** (it's an ink, not a mode), so the
  layer/ink/tool panels don't disappear. It's purely an editor decoration — **never sent to the
  simulation engine**, so it doesn't affect the circuit at all.
- **Out of the way while you draw.** Comment zones and their **"T"** markers are shown only when
  you're actually working with comments: on **every** zone while the comment ink is selected, and
  while the **selection tool** is active (so you can see and grab zones to move them). With a
  drawing tool (array/pencil/eraser/bucket) the comments **disappear entirely**, so you can draw
  circuit *under* a comment without it getting in the way. Hovering a zone fades its warm-orange
  overlay gently in and out.
- **Move a whole comment.** With the **selection tool**, click-drag a comment zone to move the
  entire group (its text comes along). The comment stays put while you drag — a green/red ghost
  shows where it'll land — and only jumps on release. A drop that would **overlap or touch another
  edited comment** (or leave the board) is refused, so the zone snaps back to where it was and two
  unrelated comments never get mixed.
- **Hover to read.** Hovering a block shows its comment as a small tooltip that **follows the
  mouse** (to the lower-right) with a soft fade in/out, and highlights that zone in orange.
- **Click to edit.** With the comment ink selected, clicking an existing block opens a popup (the
  game's dialog style) with a text zone. **Enter** saves it (**Shift+Enter** for a new line);
  click the block again anytime to change it.
- **Adjacent blocks are one comment.** Blocks placed next to each other merge into a single
  bigger comment — hovering or clicking any of them shows/edits the same text, with no seam.
- **Multiplayer-ready.** With the [VCB Multiplayer](https://github.com/n-popescu/vcb-multiplayer)
  mod in a live session, placements/removals/**moves** sync and the text **streams live** to the
  other player as you type (like the board-resize field). A late joiner receives all existing
  comments.
- **Saved with your project.** Comments are stored inside the `.vcb` file (a namespaced `modded`
  field), so they round-trip through save/load. A board with no comments saves as a clean,
  vanilla-openable file.
- **Simulation is opt-in.** During a simulation comments are hidden by default; tick the **Show
  comments** checkbox (above the Toggle/Press buttons in the Simulation panel) to reveal a comment
  and its zone on hover. You can't place or edit blocks while simulating.
- **Smooth to draw.** Placing/dragging a long comment no longer recomputes every zone's layout on
  each block — the zone markers settle once when you release — so drawing stays responsive even on
  a board full of comments.

Pure GDScript; loads at runtime, **never replaces `vcb.pck`**, and coexists with the other VCB
mods.

## How to use

Pick the comment block like any ink, then draw on the board:

1. **Select "comment"** from the **ink palette** (right bar → **Annotation** row, between Filler
   and None) or the **Q/A quick menu** (hold the ink-switch key and hover the comment entry,
   between Filler and None). Selecting it deselects the current ink — just like switching inks.
2. **Left-click or drag** on the board to place blocks (drag to paint a whole comment area). Place
   more next to a block to grow the comment.
3. **Left-click an existing block** to open the editor; type your comment and press **Enter**.
4. **Right-click or drag** to erase blocks (or use **Delete comment** in the popup to remove the
   whole group).
5. **Move a comment:** switch to the **selection tool** and click-drag a comment zone — the whole
   group (with its text) moves when you release, unless the drop would overlap/touch another
   comment.
6. **Hover** a block to read it — while the comment ink or selection tool is active in the editor,
   or (during a simulation) with the **Show comments** checkbox ticked.
7. Pick a **drawing tool** (array/pencil/eraser/bucket) to hide comments and draw circuit under them.

## Default look

A comment zone shows a small **"T"** marker (the game's `text_symbol` glyph, tinted the comment
colour) centered on the zone, plus a **warm-orange fill**. These appear only while the comment ink
or the selection tool is active (all zones), or on the single hovered zone during a simulation with
**Show comments** on — and are hidden entirely while you use a drawing tool, so comments never get
in the way of the circuit. The palette/quick-menu entry uses the same text glyph tinted the comment
colour.

The look lives in `scripts/comment_block_overlay.gd`: the fill/edge in `BLOCK_FILL`/`BLOCK_EDGE`,
the marker glyph + tint in `T_ICON_PATH`/`T_TINT`, and the fade timing in `FADE_SPEED` (the
`COMMENT` ink's colour is registered in `C.PALETTE` by `mod_main.gd`, with a `COMMENT_ACCENT`
fallback in `scripts/comment_ink_button.gd`). The on-board block size is `CELL_SIZE` in
`scripts/comment_block_sync.gd` — all easy to swap for a fuller texture later.

## Install & run

1. In the [vcb-launcher](https://github.com/n-popescu/vcb-launcher), open **Runtime modding** and
   click **Enable modding** (patches `vcb.pck` once with the Mod Loader).
2. Grab `npopescu-VCBCommentBlock.zip` from the
   [latest release](https://github.com/n-popescu/vcb-comment-block/releases/latest), or build it
   yourself: `./build.sh`.
3. Drop that zip into the game's `mods/` folder (**📁 Mods folder** in the launcher).
4. Press **▶ Launch game**.

## Build

```bash
./build.sh   # → npopescu-VCBCommentBlock.zip
```

It just zips `mods-unpacked/`. CI does the same on every commit and cuts a GitHub Release
automatically when `version_number` in `manifest.json` is bumped on `main`.

## License

MIT — see [LICENSE](LICENSE).
