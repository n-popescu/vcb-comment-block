# VCB Comment Block

A runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod for
[Virtual Circuit Board](https://store.steampowered.com/app/1885690/Virtual_Circuit_Board/) that
adds an **editor-only comment block** — a block you place on the board to annotate your circuit.

- **It's just another ink.** The comment block sits in the palette's **Annotation** row (between
  Filler and None) and in the **Q/A quick menu** (between Filler and None). Pick it like any ink
  and **draw** comment blocks with the mouse — left-click or drag to place, right-click or drag to
  erase. It's purely an editor decoration — **never sent to the simulation engine**, so it doesn't
  affect the circuit at all.
- **Hover to read.** Hovering a block shows its comment as a small tooltip that **follows the
  mouse** (to the lower-right) with a soft fade in/out.
- **Click to edit.** With the comment ink selected, clicking an existing block opens a popup (the
  game's dialog style) with a text zone. **Enter** saves it (**Shift+Enter** for a new line);
  click the block again anytime to change it.
- **Adjacent blocks are one comment.** Blocks placed next to each other merge into a single
  bigger comment — hovering or clicking any of them shows/edits the same text, with no seam.
- **Multiplayer-ready.** With the [VCB Multiplayer](https://github.com/n-popescu/vcb-multiplayer)
  mod in a live session, placements/removals sync and the text **streams live** to the other
  player as you type (like the board-resize field). A late joiner receives all existing comments.
- **Saved with your project.** Comments are stored inside the `.vcb` file (a namespaced `modded`
  field), so they round-trip through save/load. A board with no comments saves as a clean,
  vanilla-openable file.
- **Works while simulating** — you can still hover a block to read its comment; you just can't
  place or edit blocks during a simulation.

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
5. **Hover** any block (whatever ink is selected, even while simulating) to read it.
6. Pick any other **ink or tool** to go back to normal drawing.

## Default look

Until a custom texture is added, blocks are drawn as a **warm translucent square with a small
quote glyph** on the group's anchor, and the palette/quick-menu entry uses the game's text glyph
tinted the comment colour. The block colour is the `BLOCK_FILL`/`BLOCK_EDGE` constants in
`scripts/comment_block_overlay.gd` (and `COMMENT_COLOR` in `scripts/comment_ink_button.gd`), and
the on-board block size is `CELL_SIZE` in `scripts/comment_block_sync.gd` — all easy to swap for a
real texture later.

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
