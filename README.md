# VCB Comment Block

A runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod for
[Virtual Circuit Board](https://store.steampowered.com/app/1885690/Virtual_Circuit_Board/) that
adds an **editor-only comment block** — a block you place on the board to annotate your circuit.

- **Place it anywhere.** It's purely an editor decoration — it is **never sent to the simulation
  engine**, so it doesn't affect the circuit at all.
- **Hover to read.** Hovering a block shows its comment as a small tooltip that **follows the
  mouse** (to the lower-right) with a soft fade in/out.
- **Click to edit.** With comment mode on, clicking a block opens a popup (the game's dialog
  style) with a text zone. **Enter** saves it (**Shift+Enter** for a new line); click the block
  again anytime to change it.
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

Select the comment block, then work on the board:

1. **Pick "comment"** any of three ways — the **Comment** toolbar button, the comment entry in the
   **ink palette** (right bar, at the bottom of the ink grid), or the **Q/A quick menu** (hold the
   ink-switch key and hover the comment entry). Selecting it pauses the normal drawing tools.
2. **Left-click an empty spot** to place a block. Place more next to it to grow the comment area.
3. **Left-click a block** to open the editor; type your comment and press **Enter**.
4. **Hover** any block (whether or not comment mode is on, even while simulating) to read it.
5. **Right-click a block** to delete it (or use **Delete comment** in the popup to remove the
   whole group).
6. Pick any ink/tool again (palette, quick menu, or toolbar) to leave comment mode and go back to
   drawing.

## Default look

Until a custom texture is added, blocks are drawn as a **warm translucent square with a small
quote glyph** on the group's anchor, and the toolbar entry is a text **Comment** button. The
block colour is the `BLOCK_FILL`/`BLOCK_EDGE` constants in
`scripts/comment_block_overlay.gd`, and the on-board block size is `CELL_SIZE` in
`scripts/comment_block_sync.gd` — both easy to swap for a real texture later.

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
