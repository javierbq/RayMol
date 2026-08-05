# Analysis Notes

Analysis Notes keeps structural observations, hypotheses, and visual evidence beside the molecular session where they were made. Open the Inspector and choose **Notes**; edits save automatically.

Each session can contain multiple named note documents. Use the document menu beside the save status to create, switch, rename, or delete notes. View links and screenshots belong to the note where they were inserted.

## Everyday workflow

- Write plain text or Markdown. Use `#` headings for the outline and inline tags such as `#interface` for organization.
- Use the search field to filter matching lines. The outline and tag menus provide quick navigation.
- Choose the template button to append one of five scientific note structures: structural observation, binding site, interface, mutation comparison, or glycan/PTM.
- Adjust the reading size with **A−** and **A+**, then switch between **Edit** and **Preview**.
- On iPhone or iPad, tap the microphone button in the editor, then tap the microphone on Apple's keyboard to dictate into the note. Dictation uses the system keyboard and does not require separate RayMol microphone access.
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

For `experiment.pse`, RayMol stores:

Notes are stored inside the `.pse` session itself under RayMol's backward-compatible
`raymol_notes` key. Markdown and note metadata remain ordinary JSON-compatible
values; linked images are base64 encoded in a nested dictionary keyed by MD5.
**Share Session** therefore shares one self-contained file, with no sidecar or
asset folder to keep together.

RayMol keeps a temporary working/recovery copy while the session is open. Older
`.raymol-notes.json` sidecars and camera-only links remain readable and are
migrated into the next saved `.pse`.
