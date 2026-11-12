
/* 
A* -------------------------------------------------------------------
B* This file contains source code for the PyMOL computer program
C* copyright 1998-2000 by Warren Lyford Delano of DeLano Scientific. 
D* -------------------------------------------------------------------
E* It is unlawful to modify or remove this copyright notice.
F* -------------------------------------------------------------------
G* Please see the accompanying LICENSE file for further information. 
H* -------------------------------------------------------------------
I* Additional authors of this source file include:
-* 
-* 
-*
Z* -------------------------------------------------------------------
*/
#ifndef _H_RepCartoon
#define _H_RepCartoon

#include <cstddef>
#include <cstdint>

struct Rep;
struct CoordSet;
struct PyMOLGlobals;

Rep *RepCartoonNew(CoordSet * cset, int state);

/**
 * Release the shader-ready CGO (and the CPU vertex copies it owns) of
 * cartoons that no Metal frame has drawn since the last one, least recently
 * drawn first, until the cartoons' shader CGOs total at most `budget` bytes.
 * A released cartoon converts its CGO again the next time it is drawn.
 *
 * A multi-state object keeps a cartoon per state, and each state's first
 * draw made a shader CGO that stayed: playing a 300-state morph on an iPhone
 * kept about 4.8 MB per state on top of the renderer's own copies.
 *
 * @param frame CScene::ShaderCGOFrame of the frame being rendered
 */
void RepCartoonTrimShaderCGOs(PyMOLGlobals* G, size_t budget, uint64_t frame);

/** Test/diagnostic counters for RepCartoonTrimShaderCGOs. */
struct RepCartoonShaderCGOStats {
  size_t held = 0;                   // cartoons holding a shader CGO
  size_t heldBytes = 0;              // what those CGOs hold
  unsigned long long released = 0;   // released since startup
  unsigned long long releasedBytes = 0;
};
RepCartoonShaderCGOStats RepCartoonGetShaderCGOStats(PyMOLGlobals* G);

#endif
