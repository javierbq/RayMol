#!/usr/bin/env python3
"""SPIKE #625 (scratch, never merged): render.py with extra app environment.

    SPIKE625_APP_ENV='NAME=VALUE|NAME=VALUE' spike625_render.py <render.py args>

render.py's launch_env passes only its own variables to `open --env`; this
wraps it so a run can switch the spike's shader paths (RAYMOL_SPIKE625_RT,
RAYMOL_SPIKE625_PCSS) on. render.py itself is imported, never edited.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('lighting_render', os.path.join(HERE, 'render.py'))
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)

EXTRA = [x for x in os.environ.get('SPIKE625_APP_ENV', '').split('|') if x]
_orig = render.launch_env


def launch_env(*args):
    return _orig(*args) + EXTRA


render.launch_env = launch_env

if __name__ == '__main__':
    print('extra app env: %r' % (EXTRA,), flush=True)
    sys.exit(render.main(sys.argv[1:]))
