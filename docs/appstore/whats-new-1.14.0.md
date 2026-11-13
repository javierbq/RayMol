# App Store copy — RayMol 1.14.0

App Store Connect's "What's New in This Version" is plain text: no Markdown, 4000 characters max. Both store versions leave out the Sparkle "Check for Updates" footer, Homebrew, and MCP / AI clients (compiled out of both store builds), so the MCP tools and the "Claude is controlling RayMol" banner are not mentioned. The iOS copy leaves out Mac-only items (the side panel in narrow windows, the Timeline scroll-bar fix, PDF export of Notes tables).

## Promotional text (both platforms, ≤170 characters, editable without review)

New in 1.14: morphing. NMR ensembles, trajectories and predicted models now glide from one model to the next, in the viewport and in your movies.

## Mac App Store — What's New

Morphing: watch an ensemble move instead of flip.

• Turn any multi-state object (an NMR ensemble, trajectory snapshots, several predicted models) into a smooth morph. Expand it in the Objects tab and select Morph… under its State slider.
• RayMol computes the frames between consecutive models and stores them as a new object beside the original. Your models stay exactly as they are, and each one is a key frame of the morph.
• Rigid segments keeps parts that rotate in shape; Linear is faster. A clean-up pass relaxes the in-between frames.
• It builds in the background with a progress card and a Cancel button. The Morph sheet shows the frame count, length and memory before you start.
• Smooth transitions in movies: a Play models clip in the Movie tab can build the morph and play it, and exported videos play it frame by frame.
• Or type it: morph_object 2kpo. PyMOL's morph command also works, for morphing between two structures.
• Playing a long morph or trajectory keeps memory in check.

Also in this release:
• Timeline movies are saved in your sessions: reopening a .pse brings the Movie tab's lane back, ready to edit.
• Models hold still outside their Play models clips, instead of drifting through a Roll or a scene transition.
• Labels are the right size on Retina displays. They used to be drawn at half size.
• The side panel hides by itself in a narrow window, and opens over the whole window when you ask for it.
• Notes render Markdown tables, and export them to HTML and PDF.
• The Mouse panel follows your theme's accent colour.
• Fixed: a crash when a scene was deleted while its thumbnail was still being drawn, and the Timeline lane overlapping the Scenes strip when scroll bars are always shown.

## iOS / iPadOS App Store — What's New

Morphing: watch an ensemble move instead of flip.

• Turn any multi-state object (an NMR ensemble, trajectory snapshots, several predicted models) into a smooth morph. Expand it in the Objects tab and select Morph… under its State slider.
• RayMol computes the frames between consecutive models and stores them as a new object beside the original. Your models stay exactly as they are, and each one is a key frame of the morph.
• Rigid segments keeps parts that rotate in shape; Linear is faster. A clean-up pass relaxes the in-between frames.
• It builds in the background with a progress card and a Cancel button. The Morph sheet shows the frame count, length and memory before you start, and refuses a morph that would not fit in memory.
• Smooth transitions in movies: a Play models clip in the Movie tab can build the morph and play it, and exported videos play it frame by frame.
• Playing a long morph no longer runs out of memory.

Also in this release:
• Timeline movies are saved in your sessions.
• Models hold still outside their Play models clips, instead of drifting through a Roll or a scene transition.
• Labels are drawn at full size.
• Notes render Markdown tables.
• Fixed: a crash when a scene was deleted while its thumbnail was still being drawn.
