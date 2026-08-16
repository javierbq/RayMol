---
title: PyMOL Commands & API
description: An introduction to supported command syntax and Python scripting in RayMol.
---

RayMol embeds the open-source PyMOL engine and Python 3.13. Most standard PyMOL commands and the `pymol.cmd` API work as expected, although plugins or scripts that depend on desktop-only GUI toolkits or unbundled Python packages may require adaptation.

## Core commands

| Command | Example | Description |
| :--- | :--- | :--- |
| `fetch` | `fetch 1ubq, async=0` | Download a structure from the Protein Data Bank. |
| `show` / `hide` | `show cartoon, polymer` | Toggle a representation for a selection. |
| `color` | `color marine, chain A` | Apply a named color to a selection. |
| `select` | `select active_site, byres ligand around 4` | Create a named atom selection. |
| `distance` | `distance contacts, ligand, polymer, 3.5` | Create a distance measurement. |
| `save` | `save analysis.pse` | Save a structure, selection, or session based on the extension. |
| `ray` | `ray 2400, 1600` | Run PyMOL's high-quality CPU ray renderer. |

## Python scripts

Run a `.pml` or `.py` script from the console with `run path/to/script.py`. Python code can import the command API directly:

```python
from pymol import cmd

cmd.fetch("1ubq", async_=0)
cmd.show("cartoon", "1ubq")
cmd.color("marine", "1ubq")
```

See the [PyMOL command reference](https://pymolwiki.org/index.php/Category:Commands) for the broader command language.
