# Analysis Notes

Analysis Notes keeps structural observations, hypotheses, and visual evidence beside the molecular session where they were made. Open the Inspector and choose **Notes**; edits save automatically.

## Everyday workflow

- Write plain text or Markdown. Use `#` headings for the outline and inline tags such as `#interface` for organization.
- Use the search field to filter matching lines. The outline and tag menus provide quick navigation.
- Choose the template button to append one of five scientific note structures: structural observation, binding site, interface, mutation comparison, or glycan/PTM.
- Adjust the reading size with **A−** and **A+**, then switch between **Edit** and **Preview**.
- Export the note as clean Markdown from the share menu.

## View links

Choose **Insert View Link**, then select:

- **Camera Only** — restores orientation, zoom, origin, and clipping planes.
- **Full Scene** — restores the complete PyMOL scene, including representations, colors, selections, and settings captured by PyMOL.

Preview shows each link with a **Camera** or **Scene** badge. Full-scene links are stored as hidden PyMOL scenes, so save the `.pse` after inserting one. The hidden scenes do not appear in RayMol's normal Scenes panel.

On macOS, use **Option–Command–L** to insert a camera link and **Option–Command–P** to switch Edit/Preview. **Option–Command–+** and **Option–Command––** adjust note size.

## Linked Metal screenshots

The camera button in the Notes footer captures the current viewport through RayMol's Metal export pipeline and inserts it as a linked image. Screenshots appear in Preview and travel with the notes when the session is saved or shared.

## Saving and sharing

For `experiment.pse`, RayMol writes:

- `experiment.raymol-notes.json` — Markdown, view-link metadata, and image metadata.
- `experiment.raymol-notes-assets/` — linked PNG screenshots, when present.

RayMol also keeps an Application Support recovery copy for sandboxed or temporarily read-only locations. **Share Session** and **Save Session** automatically include the notes sidecar and each linked PNG. Keep those companion files with the `.pse`; full-scene links additionally depend on the scene data embedded in the saved `.pse`.

Older camera-only sidecars remain readable.
