"""
AI Mode for PyMOL - Toggle between command mode and natural language mode.

Shift+Tab toggles AI mode. In AI mode, natural language input is sent to
an LLM (Anthropic, OpenAI, or Gemini) which returns PyMOL commands that
are automatically executed.

Configuration:
  ai_config provider=anthropic          # set LLM provider
  ai_config key=sk-ant-...              # set API key
  ai_config model=claude-sonnet-4-20250514  # set model

Environment variables (checked at startup):
  PYMOL_LLM_PROVIDER    - default provider (anthropic, openai, gemini)
  ANTHROPIC_API_KEY      - Anthropic API key
  OPENAI_API_KEY         - OpenAI API key
  GEMINI_API_KEY         - Gemini API key
"""

import os
import json
import threading
import urllib.request
import urllib.error

# Module-level state
_cmd = None
_ai_mode_active = False

_ai_config = {
    'provider': os.environ.get('PYMOL_LLM_PROVIDER', 'anthropic'),
    'api_keys': {
        'anthropic': os.environ.get('ANTHROPIC_API_KEY', ''),
        'openai': os.environ.get('OPENAI_API_KEY', ''),
        'gemini': os.environ.get('GEMINI_API_KEY', ''),
    },
    'models': {
        'anthropic': 'claude-sonnet-4-20250514',
        'openai': 'gpt-4o',
        'gemini': 'gemini-2.0-flash',
    },
}

SYSTEM_PROMPT = """\
You are a PyMOL command generator. Given a natural language request, output ONLY \
valid PyMOL commands, one per line. No explanations, no markdown, no code fences.

Common commands: fetch, load, select, color, show, hide, cartoon, stick, surface, \
sphere, line, mesh, ribbon, dots, zoom, orient, center, rotate, translate, ray, png, \
set, get, distance, angle, dihedral, align, super, cealign, rms_cur, create, extract, \
delete, remove, enable, disable, group, scene, mset, mdo, mplay, isomesh, isosurface, \
map_new, spectrum, ramp_new, label, iterate, alter, sort, h_add, h_fill, split_states, \
morph, bg_color, set_color, util.cbc, util.cbag, util.cbac, util.cbam, util.cbay, \
util.cbaw, util.cbab, util.cbao, util.cbap, util.cbak, util.cbas, cmd.do

Examples:
  User: show me hemoglobin colored by chain
  Output:
  fetch 1a3n
  as cartoon
  util.cbc

  User: measure the distance between residue 42 and 87 in chain A
  Output:
  select r42, chain A and resi 42 and name CA
  select r87, chain A and resi 87 and name CA
  distance d1, r42, r87

  User: make a nice publication figure with white background
  Output:
  bg_color white
  set ray_shadow, 0
  set antialias, 2
  set ray_trace_mode, 1
  ray 2400, 1800
  png figure.png, dpi=300

Output only PyMOL commands. If you need multiple commands, put each on its own line.\
"""


def _init(cmd_module):
    """Initialize AI mode and register commands with PyMOL."""
    global _cmd
    _cmd = cmd_module
    _cmd._toggle_ai_mode = _toggle_ai_mode
    _cmd.extend('ai', _ai_toggle_command)
    _cmd.extend('ai_config', ai_config)


def _get_session_context():
    """Gather current PyMOL session state for LLM context."""
    parts = []
    try:
        objects = _cmd.get_names('objects')
        if objects:
            parts.append("Loaded objects: " + ", ".join(objects))
        selections = _cmd.get_names('selections')
        if selections:
            parts.append("Named selections: " + ", ".join(selections))
    except Exception:
        pass
    return "\n".join(parts) if parts else "Empty session (no objects loaded)."


def _ai_toggle_command(args='', _self=None):
    """Toggle AI mode on/off. Usage: ai"""
    _toggle_ai_mode(_self)


def _toggle_ai_mode(_self=None):
    """Toggle between PyMOL command mode and AI mode."""
    global _ai_mode_active
    if _self is None:
        _self = _cmd

    _ai_mode_active = not _ai_mode_active

    from pymol import _cmd as _cmd_c
    if _ai_mode_active:
        _cmd_c.set_ai_mode(_self._COb, 1)
        _cmd_c.set_prompt(_self._COb, "AI>")
        print(" AI mode ON. Type natural language and press Enter.")
        print(" Press Shift+Tab to return to PyMOL command mode.")
        provider = _ai_config['provider']
        key = _ai_config['api_keys'].get(provider, '')
        if not key:
            print(" Warning: No API key set for '%s'." % provider)
            print(" Use: ai_config key=YOUR_KEY")
            print(" Or set env: %s" % _env_var_for(provider))
    else:
        _cmd_c.set_ai_mode(_self._COb, 0)
        _cmd_c.set_prompt(_self._COb, "PyMOL>")
        print(" AI mode OFF. Back to PyMOL commands.")


def _env_var_for(provider):
    return {
        'anthropic': 'ANTHROPIC_API_KEY',
        'openai': 'OPENAI_API_KEY',
        'gemini': 'GEMINI_API_KEY',
    }.get(provider, 'UNKNOWN')


def _ai_submit(text, _self=None):
    """Called from C++ when user presses Enter in AI mode."""
    if _self is None:
        _self = _cmd
    text = text.strip()
    if not text:
        return

    provider = _ai_config['provider']
    key = _ai_config['api_keys'].get(provider, '')
    if not key:
        print(" Error: No API key for '%s'." % provider)
        print(" Use: ai_config key=YOUR_KEY")
        return

    model = _ai_config['models'].get(provider, '')
    print(" Thinking...")

    def _worker():
        try:
            context = _get_session_context()
            response = _call_provider(provider, text, context, key, model)
            commands = [c.strip() for c in response.strip().split('\n')
                        if c.strip() and not c.strip().startswith('#')]

            if not commands:
                _self.do('print " AI returned no commands."')
                return

            for c in commands:
                _self.do('print " AI> %s"' % c.replace('"', '\\"'))
                _self.do(c)

        except Exception as e:
            _self.do('print " AI Error: %s"' % str(e).replace('"', '\\"'))

    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def _call_provider(provider, user_text, context, key, model):
    """Dispatch to the appropriate LLM provider."""
    if provider == 'anthropic':
        return _call_anthropic(user_text, context, key, model)
    elif provider == 'openai':
        return _call_openai(user_text, context, key, model)
    elif provider == 'gemini':
        return _call_gemini(user_text, context, key, model)
    else:
        raise ValueError("Unknown provider: %s" % provider)


def _call_anthropic(user_text, context, key, model):
    user_message = "Session state:\n%s\n\nRequest: %s" % (context, user_text)
    payload = json.dumps({
        "model": model,
        "max_tokens": 1024,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_message}],
    }).encode('utf-8')

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        },
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode('utf-8'))
    return data["content"][0]["text"]


def _call_openai(user_text, context, key, model):
    user_message = "Session state:\n%s\n\nRequest: %s" % (context, user_text)
    payload = json.dumps({
        "model": model,
        "max_tokens": 1024,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_message},
        ],
    }).encode('utf-8')

    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
        },
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode('utf-8'))
    return data["choices"][0]["message"]["content"]


def _call_gemini(user_text, context, key, model):
    user_message = ("Session state:\n%s\n\nRequest: %s" % (context, user_text))
    full_prompt = SYSTEM_PROMPT + "\n\n" + user_message
    payload = json.dumps({
        "contents": [{"parts": [{"text": full_prompt}]}],
        "generationConfig": {"maxOutputTokens": 1024},
    }).encode('utf-8')

    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s"
           ":generateContent?key=%s" % (model, key))
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode('utf-8'))
    return data["candidates"][0]["content"]["parts"][0]["text"]


def ai_config(args='', _self=None):
    """Configure AI mode settings.

    Usage:
      ai_config                           # show current config
      ai_config provider=anthropic        # set provider
      ai_config key=sk-ant-...            # set API key for current provider
      ai_config model=claude-sonnet-4-20250514  # set model for current provider
    """
    if _self is None:
        _self = _cmd

    args = args.strip()
    if not args:
        print(" AI Mode Configuration:")
        print("   provider: %s" % _ai_config['provider'])
        print("   model:    %s" % _ai_config['models'].get(
            _ai_config['provider'], '(not set)'))
        key = _ai_config['api_keys'].get(_ai_config['provider'], '')
        if key:
            print("   key:      %s...%s" % (key[:8], key[-4:]))
        else:
            print("   key:      (not set)")
        return

    for part in args.split():
        if '=' not in part:
            print(" Error: expected key=value, got '%s'" % part)
            continue
        k, v = part.split('=', 1)
        if k == 'provider':
            if v in ('anthropic', 'openai', 'gemini'):
                _ai_config['provider'] = v
                print(" Provider set to: %s" % v)
            else:
                print(" Error: unknown provider '%s'. Use: anthropic, openai, gemini" % v)
        elif k == 'key':
            _ai_config['api_keys'][_ai_config['provider']] = v
            print(" API key set for %s" % _ai_config['provider'])
        elif k == 'model':
            _ai_config['models'][_ai_config['provider']] = v
            print(" Model set to: %s" % v)
        else:
            print(" Unknown config key: %s" % k)
