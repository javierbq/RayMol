# Analysis Notes

Analysis Notes is a session-linked scratchpad for recording structural observations directly inside RayMol. Its purpose is to keep scientific reasoning close to the molecular model, so users do not need to move repeatedly between RayMol and a separate notes application.

## Using the feature

Open the Inspector and select the **Notes** tab. Notes save automatically while you type.

- Use **A−** and **A+** to adjust the text size. RayMol remembers the chosen size.
- Zoom or rotate to an important interaction, then select **Insert View Link** and give the view a descriptive name.
- Switch from **Edit** to **Preview** to see clickable links. Selecting a view link restores the saved camera position, zoom, origin, and clipping planes.

## Storage

Notes are associated with the current PyMOL session. For a saved `.pse` file, RayMol writes a portable companion file named `<session>.raymol-notes.json`. A local Application Support copy is also maintained for recovery and for file-provider locations that are temporarily read-only.

The sidecar stores plain-text Markdown plus the camera data for each view link. It does not modify the `.pse` file and can be copied or shared alongside the session.

## Current scope

View links restore the molecular camera but do not yet restore selections, representation visibility, or colors. Links are clickable in **Preview** mode; **Edit** mode displays their Markdown source.
