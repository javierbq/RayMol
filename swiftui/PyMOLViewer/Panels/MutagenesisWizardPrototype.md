# Mutagenesis wizard prototype

This first milestone defines the mobile-first interaction model without choosing
an app presentation location or sending commands to PyMOL. Maintainer review of
the prototype should decide whether it belongs in a sheet, inspector, or
dedicated compact-width screen before live integration begins.

## Responsive layout

- Below 560 points, controls stack vertically: residue mode, selected residue,
  rotamer list, then the persistent Clear, Done, and Apply action bar.
- At 560 points and wider, residue mode and selected-residue context occupy a
  220-point leading column while the rotamer list uses the remaining width.
- Both layouts use the same state and action contract and do not depend on
  PyMOL's `internal_gui`.

## State contract

- `inactive`: no wizard controls or commands are available.
- `awaitingResidue`: mode selection and lifecycle actions are available while
  the panel asks the user to pick a residue.
- `loading`: the selected residue is visible; mode, rotamer, and Apply actions
  are disabled while Clear and Done remain available.
- `ready`: rotamers are listed; Apply becomes available only after a valid
  rotamer is selected. Changing residue mode clears a stale rotamer selection.
- `failed`: the error is visible; Apply remains disabled and Clear/Done provide
  recovery paths.

`MutagenesisWizardAction` describes mode and rotamer selection plus Apply,
Clear, and Done. The prototype controller forwards enabled actions to an
injected sink for tests, but this milestone intentionally provides no live sink,
bridge calls, or structure mutation.
