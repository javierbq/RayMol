# Analysis Notes

Analysis Notes keeps structural observations, hypotheses, and visual evidence beside the molecular session where they were made. Open the Inspector and choose **Notes**; edits save automatically.

Each session can contain multiple named note documents. Use the document menu beside the save status to create, switch, rename, or delete notes. View links and screenshots belong to the note where they were inserted.

## Everyday workflow

- Write plain text or Markdown. Use `#` headings for the outline and inline tags such as `#interface` for organization.
- Use the search field to filter matching lines. The outline and tag menus provide quick navigation.
- Choose the template button to append one of five scientific note structures: structural observation, binding site, interface, mutation comparison, or glycan/PTM.
- Adjust the reading size with **A−** and **A+**, then switch between **Edit** and **Preview**.
- Export the note as clean Markdown from the share menu.

## Scientific inserts

The atom-shaped insert menu reads live data from the current RayMol session:

- **Selected Residues** inserts the residues in PyMOL's current `sele` selection.
- **Contacts Around Selection** inserts residues outside `sele` that lie within 4.0 Å.
- **Current Measurements** inserts distances, angles, and dihedrals created with RayMol's measurement tool during the current run.

Residue identifiers in the first two inserts are clickable in Preview. Clicking one creates the `sele` selection in 3D and zooms to that residue.

## View links

Choose **Insert View Link**, then select:

- **Camera Only** — restores orientation, zoom, origin, and clipping planes.
- **Full Scene** — restores the complete PyMOL scene, including representations, colors, selections, and settings captured by PyMOL.

Preview shows each link with a **Camera** or **Scene** badge. Full-scene links are stored as hidden PyMOL scenes, so save the `.pse` after inserting one. The hidden scenes do not appear in RayMol's normal Scenes panel.

On macOS, use **Option–Command–L** to insert a camera link and **Option–Command–P** to switch Edit/Preview. **Option–Command–+** and **Option–Command––** adjust note size.

## Linked Metal screenshots

The camera button in the Notes footer captures the current viewport through RayMol's Metal export pipeline and inserts it as a linked image. Screenshots appear in Preview and travel with the notes when the session is saved or shared.

## Export and detachable window

The export menu supports clean Markdown, self-contained HTML with base64-embedded screenshots, and paginated PDF with images, headings, page numbers, and captions.

On macOS, choose the window button in the Notes footer to open a detachable **Analysis Notes** window. It stays synchronized with the Notes inspector and can remain beside the molecular viewport.

## Saving and sharing

For `experiment.pse`, RayMol writes:

- `experiment.raymol-notes.json` — Markdown, view-link metadata, and image metadata.
- `experiment.raymol-notes-assets/` — linked PNG screenshots, when present.

RayMol also keeps an Application Support recovery copy for sandboxed or temporarily read-only locations. **Share Session** and **Save Session** automatically include the notes sidecar and each linked PNG. Keep those companion files with the `.pse`; full-scene links additionally depend on the scene data embedded in the saved `.pse`.

Older camera-only sidecars remain readable.
