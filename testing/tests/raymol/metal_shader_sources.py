"""Metal shader source hygiene: cross-library helper visibility and raw-string
termination in RendererMetal.mm.

RendererMetal.mm compiles its post-processing library (kPostSrc) and its
ray-tracing library (kRTSrc) from separate MSL string literals with
newLibraryWithSource:, each with the shared kEyeReconSrc block prepended. Metal
does no cross-library linking, so a helper defined only in kPostSrc is an
undeclared identifier in kRTSrc. That is a RUNTIME shader-compile failure no
C++ build catches: the RT pipelines are never created and metal_raytrace
silently does nothing (PR #100 fixed exactly that after the #83/#87 shadow work
moved post_eye_* into kPostSrc). rt_composite's depth-aware AO blur now calls
post_linear_depth as well, so that helper has to live in the shared block too.

The literals are Objective-C raw strings, @R"(...)", which end at the FIRST
')"'. A ')"' anywhere in the shader text -- a quoted expression in a comment
is enough -- truncates the literal and breaks the C++ compile.

Pure source parsing: no GPU and no Metal toolchain, so it runs everywhere.

    pymol -ckqy testing/testing.py --run tests/raymol/metal_shader_sources.py
"""
import os
import re

from pymol import testing

SOURCE = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')

_LITERAL = re.compile(r'static NSString\* const (k\w+) = @R"\((.*?)\)"(.)', re.S)
# Hand-written helpers in these literals are post_* / rt_*; everything else that
# looks like a call is an MSL builtin (smoothstep, sample_compare, ...).
_DEF = re.compile(
    r'^\s*(?:static\s+|fragment\s+|vertex\s+)?[\w:<>]+\s+((?:post|rt)_\w+)\s*\(',
    re.M)
_CALL = re.compile(r'\b((?:post|rt)_\w+)\s*\(')


def shader_literals(source):
    """{name: body} for every @R"(...)" literal in `source`.

    Raises AssertionError when a literal is cut short by a ')"' inside the
    shader text, which is what the C++ compiler would see too.
    """
    literals = {}
    for match in _LITERAL.finditer(source):
        name, body, after = match.groups()
        if after != ';':
            raise AssertionError(
                '%s: raw string terminated early by \')"\' in the shader text, '
                'near %r' % (name, body[-60:]))
        literals[name] = body
    return literals


def undefined_helpers(body):
    """post_/rt_ helpers that `body` calls but does not define."""
    return set(_CALL.findall(body)) - set(_DEF.findall(body))


class TestMetalShaderSources(testing.PyMOLTestCase):

    def source(self):
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir,
                            os.pardir)
        path = os.path.normpath(os.path.join(root, SOURCE))
        if not os.path.isfile(path):
            # Skipped, not passed: a source-reading test that cannot find its
            # source has checked nothing. Only reached outside a repo checkout.
            self.skipTest('%s not present; not a repo checkout' % SOURCE)
        with open(path) as handle:
            return handle.read()

    def testRawStringsEndWhereIntended(self):
        literals = shader_literals(self.source())
        for name in ('kEyeReconSrc', 'kPostSrc', 'kRTSrc'):
            self.assertIn(name, literals)

    def testEachLibraryIsSelfContained(self):
        """Every helper a library calls is visible in shared + that library."""
        literals = shader_literals(self.source())
        shared = literals['kEyeReconSrc']
        for lib in ('kPostSrc', 'kRTSrc'):
            missing = undefined_helpers(shared + literals[lib])
            self.assertFalse(
                missing, '%s calls helpers it cannot see at runtime: %s'
                % (lib, sorted(missing)))

    def testRTBlurUsesTheSharedOrthoAwareDepth(self):
        """rt_composite's bilateral AO blur must reconstruct the neighbour depth
        with the same ortho-aware inverse as the centre sample (#139), not the
        perspective-only formula it inlined before."""
        rt = shader_literals(self.source())['kRTSrc']
        composite = rt[rt.index('fragment float4 rt_composite('):]
        self.assertIn('post_linear_depth(dn, u.projA, u.projB, u.projOrtho)',
                      composite)
        self.assertNotIn('-u.projB / ((2.0 * dn - 1.0) + u.projA)', composite)
