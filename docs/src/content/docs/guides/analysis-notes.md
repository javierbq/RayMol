---
title: Analysis Notes
description: Record observations, link molecular views, and capture structured object and residue references inside a RayMol session.
---

Analysis Notes is a session-linked laboratory scratchpad. Use it to record an
interpretation beside the structure, preserve the exact view that led to an
observation, and pass a documented `.pse` session to a collaborator.

Open **Notes** in the inspector. Use **Edit** to write Markdown and **Preview**
to read the formatted result and follow interactive links.

## Keep notes with a session

Notes, named note pages, view links, and linked images are embedded when you
save the RayMol session as a `.pse` file. Sharing that session therefore shares
its analysis record as well. Unsaved work is staged locally for recovery, but a
saved session is the portable copy you should archive or send to someone else.

Use the note-page menu to create, rename, switch, or delete separate documents
within one session. Search filters the current note, while the outline and tag
menus help navigate Markdown headings and tags such as `#interface`.

## Link an observation to the 3D view

Choose **Insert Image / View** at the bottom of Notes:

- **Image from Current View** inserts a rendered snapshot.
- **Camera Link** saves the current orientation and zoom. Following the link
  restores the camera without intentionally changing object visibility or
  representations.
- **Scene Link** stores a PyMOL scene. Following the link restores the broader
  scene state as well as the view.

Name the link for the scientific observation—for example, `NAG301 hydrogen
bond`—instead of accepting a generic name. In Preview, select the linked image
or view name to return to that state.

## Insert scientific data

The atom menu can add contacts around the active `sele` selection and current
measurements. RayMol leaves the note unchanged and shows an alert when there is
nothing available to insert.

:::note[Structured logging preview]
The faster object and residue-reference workflow below is proposed in
[PR #753](https://github.com/javierbq/RayMol/pull/753). It becomes available
when that change is merged and included in a build.
:::

### Reference an object with `@`

Type `@` in the editor and continue typing any part of an object name. Use the
arrow keys and **Return** or **Tab**, or select a result, to insert an
unambiguous object marker:

```text
[Object: object="4tuj"]
```

### Insert the current selection

Create or update the normal PyMOL `sele` selection, place the note caret where
the references should go, and choose **Insert Current Selection** (the scope
button). RayMol inserts each unique residue on its own line in a stable order.

Residue references preserve object, segment, chain, residue name, and residue
identifier—including insertion codes and deliberately empty fields:

```text
[Residue: object="4tuj" segi="" chain="D" resn="NAG" resi="301B"]
```

This complete format is intended to remain useful after a session is reopened
and to be straightforward for scripts or AI tools to parse.

### Capture repeated picks with Logbook Mode

Enable **Logbook Mode** (the record button), then continue selecting residues
in the 3D viewport. Each successful pick appends a new line to the active note
without moving keyboard focus away from the structure:

```markdown
- **[Residue: object="4tuj" segi="" chain="D" resn="NAG" resi="301B"]**:
```

Logbook Mode is deliberately off when RayMol or a session is reopened. Normal
clicks keep their usual selection and information behavior, and RayMol does not
write residue references to the system clipboard.

On macOS, **Option-click** a residue to insert its structured reference at the
last saved note caret instead. The ordinary PyMOL pick still occurs, and the
insertion participates in the editor's normal undo history.

## Export the record

Use the share menu at the bottom of Notes to export clean Markdown, HTML with
images, or PDF with images. Exported files are useful for reports, but the
`.pse` session remains the format that preserves RayMol's interactive camera
and scene links.

