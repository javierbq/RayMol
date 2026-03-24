"""AI Chat conversation engine for PyMOL — multi-turn, agentic LLM integration."""

import os
import json
import threading
import urllib.request
import urllib.error

_cmd = None
_has_ui = False
_messages = []  # list of {'role': str, 'content': str}

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
You are an AI assistant controlling PyMOL, a molecular visualization tool. \
You generate PyMOL commands to fulfill user requests.

Rules:
- Output PyMOL commands, one per line
- Do NOT use markdown code fences
- You may include a brief explanation line (starting with #) before commands
- After your commands execute, you will see the results
- If a command errors, analyze the error and try a corrected approach
- Use the session state to understand what's currently loaded

Common commands: fetch, load, select, color, show, hide, cartoon, stick, surface, \
sphere, line, ribbon, zoom, orient, center, rotate, ray, png, set, get, \
distance, angle, align, super, cealign, create, extract, delete, remove, \
enable, disable, group, spectrum, label, iterate, alter, h_add, bg_color, \
set_color, util.cbc, util.cbag, util.cbac, util.cbam, util.cbay\
"""


def _init(cmd_module):
    """Initialize the AI chat module, registering commands and optional UI."""
    global _cmd, _has_ui

    _cmd = cmd_module

    # Re-read env vars (may have been set from ~/.pymol_ai.conf after module load)
    _ai_config['provider'] = os.environ.get('PYMOL_LLM_PROVIDER', _ai_config['provider'])
    for provider in _ai_config['api_keys']:
        env_key = provider.upper() + '_API_KEY'
        val = os.environ.get(env_key, '')
        if val:
            _ai_config['api_keys'][provider] = val

    try:
        from pymol import ai_chat_ui
        _has_ui = True
        ai_chat_ui._init()
    except ImportError:
        _has_ui = False

    cmd_module.extend('ai_config', ai_config)


def ai_config(args='', _self=None):
    """Show or set AI provider configuration.

    Usage:
        ai_config                        # show current config
        ai_config provider=openai        # set provider
        ai_config key=sk-...             # set API key for current provider
        ai_config model=gpt-4o           # set model for current provider
    """
    global _ai_config

    if not args or not args.strip():
        provider = _ai_config['provider']
        key = _ai_config['api_keys'].get(provider, '')
        masked_key = (key[:8] + '...' + key[-4:]) if len(key) > 12 else ('***' if key else '(not set)')
        model = _ai_config['models'].get(provider, '(not set)')
        print(f"AI Config:")
        print(f"  provider : {provider}")
        print(f"  key      : {masked_key}")
        print(f"  model    : {model}")
        return

    pairs = {}
    for token in args.strip().split():
        if '=' in token:
            k, _, v = token.partition('=')
            pairs[k.strip()] = v.strip()

    if 'provider' in pairs:
        new_provider = pairs['provider'].lower()
        if new_provider not in _ai_config['api_keys']:
            print(f"Unknown provider '{new_provider}'. Supported: {', '.join(_ai_config['api_keys'].keys())}")
        else:
            _ai_config['provider'] = new_provider
            print(f"Provider set to '{new_provider}'.")

    if 'key' in pairs:
        provider = _ai_config['provider']
        _ai_config['api_keys'][provider] = pairs['key']
        print(f"API key updated for provider '{provider}'.")

    if 'model' in pairs:
        provider = _ai_config['provider']
        _ai_config['models'][provider] = pairs['model']
        print(f"Model set to '{pairs['model']}' for provider '{provider}'.")


def _toggle_panel():
    """Toggle the AI chat panel, if the UI module is available."""
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.toggle()
    else:
        print("Chat panel requires macOS with pyobjc-framework-Cocoa.")


def _get_session_context():
    """Return a short text description of the current PyMOL session state.

    NOTE: This function is currently unused. Calling _cmd.get_names() from
    the worker thread deadlocks because it tries to acquire the API lock
    that the render loop holds. A future approach could use cmd.do() to
    queue the query on the main thread and pass results back.
    """
    parts = []
    try:
        objects = _cmd.get_names('objects')
        if objects:
            parts.append("Loaded objects: " + ", ".join(objects))
        selections = _cmd.get_names('selections')
        if selections:
            parts.append("Named selections: " + ", ".join(selections))
    except Exception:
        parts.append("(session state unavailable)")
    return "\n".join(parts) if parts else "Empty session (no objects loaded)."


def _on_user_message(text):
    """Main entry point called by the UI when the user submits a message."""
    global _messages

    _messages.append({'role': 'user', 'content': text})

    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.show_message('user', text)
        ai_chat_ui.show_status('Thinking...')

    provider = _ai_config['provider']
    key = _ai_config['api_keys'].get(provider, '')
    if not key:
        error_msg = (
            f"No API key set for provider '{provider}'. "
            f"Run: ai_config key=YOUR_KEY"
        )
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.show_message('assistant', error_msg)
            ai_chat_ui.show_status('')
        else:
            print(error_msg)
        return

    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def _worker():
    """Background thread: call LLM, execute commands, retry on errors."""
    global _messages

    max_retries = 2
    attempt = 0

    # Thread-safe UI helpers -- dispatch to main thread
    def _ui_msg(role, text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_on_main_thread(role, text, [])

    def _ui_status(text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui._StatusUpdater._text = text
            ai_chat_ui._StatusUpdater.alloc().init().performSelectorOnMainThread_withObject_waitUntilDone_(
                'doStatus:', None, False)

    try:
        while attempt <= max_retries:
            try:
                response_text = _call_llm()
            except Exception as exc:
                error_msg = f"LLM call failed: {exc}"
                _messages.append({'role': 'assistant', 'content': error_msg})
                _ui_msg('error', error_msg)
                _ui_status('')
                return

            _messages.append({'role': 'assistant', 'content': response_text})
            _ui_msg('assistant', response_text)
            _ui_status('Executing...')

            results = _execute_commands(response_text)
            errors = [r for r in results if r.startswith('Error:')]
            # Only show errors in the chat, not OK confirmations
            for r in errors:
                _ui_msg('error', r)

            if not errors or attempt >= max_retries:
                _ui_status('')
                break

            retry_content = (
                "The following commands had errors:\n"
                + "\n".join(errors)
                + "\nPlease fix and try again."
            )
            _messages.append({'role': 'user', 'content': retry_content})
            _ui_status('Retrying...')
            attempt += 1

    except Exception as exc:
        _ui_msg('error', f"Unexpected error: {exc}")
        _ui_status('')


def _call_llm():
    """Build the message list and call the configured LLM provider."""
    provider = _ai_config['provider']
    key = _ai_config['api_keys'].get(provider, '')
    model = _ai_config['models'].get(provider, '')

    # Build messages (session context omitted; see _get_session_context docstring)
    messages = [{'role': m['role'], 'content': m['content']} for m in _messages]

    if provider == 'anthropic':
        return _call_anthropic(messages, key, model)
    elif provider == 'openai':
        return _call_openai(messages, key, model)
    elif provider == 'gemini':
        return _call_gemini(messages, key, model)
    else:
        raise ValueError(f"Unknown provider: {provider}")


def _execute_commands(response_text):
    """Extract PyMOL commands from the LLM response and execute them.

    Only lines inside markdown code blocks (```...```) are treated as
    commands. Plain text lines are ignored.

    Returns a list of result strings.
    """
    results = []
    in_code_block = False
    commands = []

    for line in response_text.splitlines():
        stripped = line.strip()
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        if in_code_block and stripped and not stripped.startswith('#'):
            commands.append(stripped)

    # If no code blocks found, try to detect bare PyMOL commands
    # (lines starting with known PyMOL verbs)
    if not commands:
        _PYMOL_VERBS = {
            'fetch', 'load', 'select', 'color', 'show', 'hide', 'set',
            'bg_color', 'orient', 'zoom', 'center', 'ray', 'png', 'save',
            'align', 'super', 'cealign', 'delete', 'remove', 'create',
            'spectrum', 'label', 'distance', 'angle', 'dihedral',
            'cartoon', 'surface', 'stick', 'sphere', 'line', 'mesh',
            'enable', 'disable', 'reset', 'turn', 'move', 'clip',
            'viewport', 'split_states', 'util', 'cmd',
        }
        for line in response_text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            first_word = stripped.split('(')[0].split()[0].lower() if stripped else ''
            if first_word in _PYMOL_VERBS:
                commands.append(stripped)

    for cmd_line in commands:
        try:
            _cmd.do(cmd_line, 0, 1)
            results.append(f"OK: {cmd_line}")
        except Exception as exc:
            results.append(f"Error: {cmd_line} => {exc}")

    return results


# ---------------------------------------------------------------------------
# LLM provider implementations
# ---------------------------------------------------------------------------

def _call_anthropic(messages, key, model):
    """Call the Anthropic Messages API with a multi-turn conversation."""
    url = 'https://api.anthropic.com/v1/messages'

    # Anthropic requires alternating user/assistant roles; build payload
    payload = {
        'model': model,
        'max_tokens': 1024,
        'system': SYSTEM_PROMPT,
        'messages': [{'role': m['role'], 'content': m['content']} for m in messages],
    }

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            'Content-Type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
        },
        method='POST',
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode('utf-8'))
        return body['content'][0]['text']
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Anthropic HTTP {exc.code}: {error_body}") from exc


def _call_openai(messages, key, model):
    """Call the OpenAI Chat Completions API with a multi-turn conversation."""
    url = 'https://api.openai.com/v1/chat/completions'

    oai_messages = [{'role': 'system', 'content': SYSTEM_PROMPT}]
    oai_messages += [{'role': m['role'], 'content': m['content']} for m in messages]

    payload = {
        'model': model,
        'messages': oai_messages,
        'max_tokens': 1024,
    }

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {key}',
        },
        method='POST',
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode('utf-8'))
        return body['choices'][0]['message']['content']
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"OpenAI HTTP {exc.code}: {error_body}") from exc


def _call_gemini(messages, key, model):
    """Call the Google Gemini generateContent API with a multi-turn conversation."""
    url = (
        f'https://generativelanguage.googleapis.com/v1beta/models/{model}'
        f':generateContent?key={key}'
    )

    # Gemini uses 'user' and 'model' roles (not 'assistant')
    def _gemini_role(role):
        return 'model' if role == 'assistant' else 'user'

    contents = [
        {
            'role': _gemini_role(m['role']),
            'parts': [{'text': m['content']}],
        }
        for m in messages
    ]

    payload = {
        'contents': contents,
        'systemInstruction': {
            'parts': [{'text': SYSTEM_PROMPT}],
        },
    }

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode('utf-8'))
        return body['candidates'][0]['content']['parts'][0]['text']
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Gemini HTTP {exc.code}: {error_body}") from exc


def clear_conversation():
    """Reset the conversation history and clear the UI (if available)."""
    global _messages
    _messages = []
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.clear_messages()
