Render inspection of #619 round-1 images (mac-bar/01..10, sim-portrait-sheet.png, sim-landscape-sheet.png) at head 241ab0f83, PR #647. Looked only; nothing built or rendered. 14 tiles: 14 PASS, 0 FAIL, 0 UNSURE.

| image | verdict | reason |
| --- | --- | --- |
| round-1/mac-bar/01_wide_0_light.png | PASS | Status text "No lights · add one or pick a preset"; + live; −, Re-centre, power and Revert dimmed; Presets and Done present; nothing clipped. |
| round-1/mac-bar/02_wide_3_fill_selected_light.png | PASS | key (blue), fill (orange, accent capsule = selected), rim (green) chips; +, −, Presets, Re-centre live; power icon accent blue; Revert dimmed; Done grey (window not key, expected). |
| round-1/mac-bar/03_wide_6_light.png | PASS | Six chips (key, fill, rim, light4, light5, light6) with distinct dots, all legible, no overlap; + dimmed at the 6-light cap; key selected. |
| round-1/mac-bar/04_wide_3_off_light.png | PASS | Chips visibly dimmed, power icon no longer accent blue; Presets and Re-centre remain live; Revert dimmed. Matches "rig off". |
| round-1/mac-bar/05_wide_0_dark.png | PASS | Dark appearance: dark bar, light text, same dimming pattern as 01; legible. |
| round-1/mac-bar/06_wide_3_fill_selected_dark.png | PASS | Dark: fill selected with accent outline, power accent blue, chips and dots legible. |
| round-1/mac-bar/07_wide_6_dark.png | PASS | Dark: six chips legible, no overlap; + dimmed. |
| round-1/mac-bar/08_wide_3_off_dark.png | PASS | Dark: chips dimmed, power icon not accent; text still readable (low contrast on the dimmed chips is intended). |
| round-1/mac-bar/09_compact_3_light.png | PASS | 600 pt strip, fill selected, everything fits with no clipping. Note: it renders the wide layout (Lights title and Presets menu still shown), not the compact one, so only tile 10 shows the compact layout. This agrees with evidence.md, which says only the 6-light 600 pt shot switches to compact. |
| round-1/mac-bar/10_compact_6_light.png | PASS | Compact layout: bulb icon only (title dropped), six chips fit, +, −, ellipsis (Presets and the rest folded in), Revert dimmed, Done; + dimmed at 6 lights; no clipping. |
| round-1/sim-portrait-sheet.png (iPhone portrait) | PASS | Compact bar sits under the Console and Seq panes and above the viewport; key, fill (selected capsule), rim; +, −, ellipsis, Revert dimmed, Done in accent; viewport not black or blank: lit green cartoon with specular highlights; the Lights pill is in the top row. |
| round-1/sim-portrait-sheet.png (iPad portrait) | PASS | Wide bar (Lights title, three chips with fill selected, +, −, Presets, Re-centre, power, Revert, Done) docked under the console and sequence panes, above the viewport, as specced; no clipping; viewport shows the lit cartoon; the panels below are intact. Small on the sheet, so fine detail is not checked. |
| round-1/sim-landscape-sheet.png (iPhone landscape) | PASS | Compact bar under the sequence pane, spanning the viewport column; chips, +, −, ellipsis, Revert, Done all visible and unclipped; the lit cartoon renders; the side panel and the viewport/panel handle are intact. |
| round-1/sim-landscape-sheet.png (iPad, AUTOLANDSCAPE not rotated) | PASS | As evidence.md says, the shot is still portrait (an expected limit, not a failure). Wide bar under the console and sequence panes, above the viewport; lit cartoon; no defects. |

Notes (not defects of the bar): the sequence ruler on the iPad shots shows crowded digits at the right edge ("8880") and the sequence strip shows "HOHOHO" water residues. Both are in the pre-existing sequence pane, outside the diff. Not covered by these images: opening the Presets or ellipsis menus, and tapping behaviour; the macOS on-screen placement is on the manual list.
