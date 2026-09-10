---
title: Glycobiology
description: Visualize, select, and inspect carbohydrate residues with SNFG-aware tools in RayMol.
---

RayMol's glycobiology tools combine the PyMOL molecular model with native
Metal rendering. Recognized carbohydrate residues can be colored and displayed
as three-dimensional symbols while the original atomic structure remains
available for inspection.

:::caution[Development preview]
These tools are being developed on the `agent/snfg-glycan-cartoons` and
`feature/glyco-remediation-torsion-tree` branches. Command names, supported
residue codes, and the topology interface may change before they are merged and
released.
:::

## SNFG conventions

RayMol follows the Symbol Nomenclature for Glycans (SNFG) color and shape
conventions for its supported residue catalog. Consult the
[official NCBI SNFG reference](https://www.ncbi.nlm.nih.gov/glycans/snfg.html)
for the symbol standard, color table, and current nomenclature guidance.

The first implementation focuses on common mammalian monosaccharides,
including GlcNAc, GalNAc, Man, Gal, Glc, Fuc, Neu5Ac, and Neu5Gc. Unsupported or
incomplete residues are left unchanged rather than assigned a potentially
incorrect symbol.

## Display an SNFG glycan cartoon

Load a glycoprotein such as PDB entry 4TUJ, then run:

```text
fetch 4tuj, async=0
glycocolor 4tuj
glycocartoon 4tuj
```

You can also choose **Show → Glycan cartoon** from an object row in the Objects
panel. Linkers are derived from actual covalent bonds; RayMol does not connect
residues merely because they are close in space. Clicking a rendered sugar
symbol selects its underlying molecular residue, so the normal selection and
inspection tools remain available.

To remove only the generated symbols for that object:

```text
glycocartoon_hide 4tuj
```

## Inspect topology and geometry

The analysis preview adds a glycan-topology button to the Objects section. Its
tree is built from inter-residue covalent bonds and rooted at the protein or
other non-glycan attachment when one is present. Selecting a row focuses the
corresponding residue in the 3D view.

Each node may include:

- its PDB residue code and mapped SNFG name;
- a six-membered-ring Cremer–Pople puckering description;
- measured glycosidic φ, ψ, and, where available, ω torsions; and
- the bond connecting it to its parent residue.

Identity suggestions, puckering labels, and torsion measurements are advisory.
They do not alter residue names or coordinates and should be checked against
carbohydrate-aware validation and the experimental evidence.

The same data can be inspected from the RayMol console:

```text
glyco_tree 4tuj
glyco_remediate 4tuj
```
