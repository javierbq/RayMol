"""AI Chat conversation engine for PyMOL — agentic LLM integration with tool use.

Uses the Anthropic Messages API with streaming SSE and tool_use for an
agentic loop: the model can call tools (get_session_state, execute_command,
capture_viewport, search_pdb), inspect results, and iterate until it produces
a final structured JSON response with {response, script, questions}.
"""

import os
import json
import threading
import urllib.request
import urllib.error

_cmd = None
_has_ui = False
_messages = []  # list of {'role': str, 'content': str | list}

_ai_config = {
    'provider': 'anthropic',
    'api_keys': {
        'anthropic': os.environ.get('ANTHROPIC_API_KEY', ''),
    },
    'models': {
        'anthropic': 'claude-sonnet-4-20250514',
    },
}

from pymol.ai_system_prompt import SYSTEM_PROMPT

# Try to import tool definitions (created by Agent B)
try:
    from pymol.ai_tools import TOOL_DEFINITIONS, execute_tool
except ImportError:
    TOOL_DEFINITIONS = []
    def execute_tool(name, tool_input, cmd):
        return json.dumps({"error": f"Tool '{name}' not available — ai_tools module not found."})


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
        ai_config key=sk-...             # set API key
        ai_config model=claude-sonnet-4-20250514  # set model
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


def _on_user_message(text):
    """Main entry point called by the UI when the user submits a message."""
    global _messages

    _messages.append({'role': 'user', 'content': text})

    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.show_message('user', text)
        ai_chat_ui.show_status('Thinking...')

    key = _ai_config['api_keys'].get('anthropic', '')
    if not key:
        error_msg = (
            "No API key set. "
            "Run: ai_config key=YOUR_ANTHROPIC_API_KEY"
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


# ---------------------------------------------------------------------------
# Agentic worker loop
# ---------------------------------------------------------------------------

def _worker():
    """Background thread: agentic loop with streaming and tool use.

    1. Stream API call with tools
    2. Handle text_delta (update streaming bubble)
    3. Handle tool_use blocks (execute tools, send tool_result back)
    4. Loop until stop_reason == "end_turn"
    5. Parse final text as JSON {response, script, questions}
    6. Execute script silently, show questions
    """
    global _messages

    def _ui_status(text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui._StatusUpdater._text = text
            ai_chat_ui._StatusUpdater.alloc().init().performSelectorOnMainThread_withObject_waitUntilDone_(
                'doStatus:', None, False)

    def _ui_msg(role, text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_on_main_thread(role, text, [])

    def _ui_begin_stream():
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.run_on_main_thread(ai_chat_ui.begin_streaming_message)

    def _ui_update_stream(text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_streaming_message(text)

    def _ui_finalize_stream():
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.finalize_streaming_message()

    try:
        key = _ai_config['api_keys'].get('anthropic', '')
        model = _ai_config['models'].get('anthropic', '')

        while True:
            # Build clean messages for the API
            api_messages = _build_api_messages()

            # Start streaming
            _ui_begin_stream()
            accumulated_text = ''
            stop_reason = None
            content_blocks = []  # collected content blocks from the response

            # Current block tracking
            current_block_type = None
            current_block_id = None
            current_block_name = None
            current_block_text = ''
            current_block_json = ''

            def on_text_delta(delta_text):
                nonlocal accumulated_text
                accumulated_text += delta_text
                _ui_update_stream(accumulated_text)

            def on_content_block_start(block):
                nonlocal current_block_type, current_block_id, current_block_name
                nonlocal current_block_text, current_block_json
                btype = block.get('type', '')
                current_block_type = btype
                if btype == 'tool_use':
                    current_block_id = block.get('id', '')
                    current_block_name = block.get('name', '')
                    current_block_json = ''
                elif btype == 'text':
                    current_block_text = ''

            def on_content_block_delta(delta):
                nonlocal current_block_text, current_block_json
                dtype = delta.get('type', '')
                if dtype == 'text_delta':
                    text = delta.get('text', '')
                    current_block_text += text
                    on_text_delta(text)
                elif dtype == 'input_json_delta':
                    current_block_json += delta.get('partial_json', '')

            def on_content_block_stop():
                nonlocal current_block_type
                if current_block_type == 'text':
                    content_blocks.append({
                        'type': 'text',
                        'text': current_block_text,
                    })
                elif current_block_type == 'tool_use':
                    try:
                        tool_input = json.loads(current_block_json) if current_block_json else {}
                    except json.JSONDecodeError:
                        tool_input = {}
                    content_blocks.append({
                        'type': 'tool_use',
                        'id': current_block_id,
                        'name': current_block_name,
                        'input': tool_input,
                    })
                current_block_type = None

            def on_message_delta(delta):
                nonlocal stop_reason
                stop_reason = delta.get('stop_reason', stop_reason)

            try:
                _call_anthropic_streaming(
                    api_messages, key, model,
                    on_content_block_start=on_content_block_start,
                    on_content_block_delta=on_content_block_delta,
                    on_content_block_stop=on_content_block_stop,
                    on_message_delta=on_message_delta,
                )
            except Exception as exc:
                _ui_finalize_stream()
                error_msg = f"API call failed: {exc}"
                _messages.append({'role': 'assistant', 'content': error_msg})
                _ui_msg('error', error_msg)
                _ui_status('')
                return

            _ui_finalize_stream()

            # Store assistant response in conversation history
            # Use content blocks format if there are tool_use blocks
            if any(b['type'] == 'tool_use' for b in content_blocks):
                _messages.append({'role': 'assistant', 'content': content_blocks})
            else:
                # Plain text
                full_text = ''.join(b.get('text', '') for b in content_blocks if b['type'] == 'text')
                _messages.append({'role': 'assistant', 'content': full_text})

            # If stop_reason is tool_use, execute tools and loop
            if stop_reason == 'tool_use':
                _ui_status('Using tools...')
                tool_results = []
                for block in content_blocks:
                    if block['type'] != 'tool_use':
                        continue
                    tool_name = block['name']
                    tool_input = block['input']
                    tool_id = block['id']

                    try:
                        result = execute_tool(tool_name, tool_input, _cmd)
                    except Exception as exc:
                        result = json.dumps({"error": str(exc)})

                    # Build tool_result content block
                    # Check if result is an image (for capture_viewport)
                    try:
                        result_parsed = json.loads(result) if isinstance(result, str) else result
                    except (json.JSONDecodeError, TypeError):
                        result_parsed = None

                    if (isinstance(result_parsed, dict)
                            and result_parsed.get('type') == 'image'
                            and 'data' in result_parsed):
                        tool_results.append({
                            'type': 'tool_result',
                            'tool_use_id': tool_id,
                            'content': [{
                                'type': 'image',
                                'source': {
                                    'type': 'base64',
                                    'media_type': result_parsed.get('media_type', 'image/png'),
                                    'data': result_parsed['data'],
                                }
                            }],
                        })
                    else:
                        result_str = result if isinstance(result, str) else json.dumps(result)
                        tool_results.append({
                            'type': 'tool_result',
                            'tool_use_id': tool_id,
                            'content': result_str,
                        })

                # Add tool results as a user message
                _messages.append({'role': 'user', 'content': tool_results})
                _ui_status('Thinking...')
                # Reset for next iteration
                continue

            # stop_reason == "end_turn" (or anything else) — we're done
            full_text = ''.join(b.get('text', '') for b in content_blocks if b['type'] == 'text')

            # Parse structured response
            parsed = _parse_structured_response(full_text)
            response_text = parsed.get('response', full_text)
            script = parsed.get('script', '')
            questions = parsed.get('questions', [])

            # The streaming bubble already showed the raw text; if we parsed
            # a structured response, show the clean version instead
            if response_text != full_text and response_text:
                _ui_msg('assistant', response_text)

            # Execute script silently on main thread
            if script:
                _ui_status('Executing...')
                _execute_script(script)

            # Show question buttons
            if questions and _has_ui:
                from pymol import ai_chat_ui
                ai_chat_ui.show_question_buttons(questions)

            _ui_status('')
            break

    except Exception as exc:
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.finalize_streaming_message()
        _ui_msg('error', f"Unexpected error: {exc}")
        _ui_status('')


def _build_api_messages():
    """Build a clean message list for the Anthropic API.

    Handles both string content and list-of-blocks content (for tool_use turns).
    Ensures proper alternating user/assistant roles.
    """
    api_messages = []
    for m in _messages:
        role = m['role']
        content = m['content']
        api_messages.append({'role': role, 'content': content})
    return api_messages


# ---------------------------------------------------------------------------
# Structured response parsing
# ---------------------------------------------------------------------------

def _parse_structured_response(text):
    """Extract JSON {response, script, questions} from the model's text.

    The model is instructed to respond with JSON. This function tries to
    extract it, with a fallback to treating the entire text as a plain
    response (no script, no questions).
    """
    text = text.strip()

    # Try direct JSON parse
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict) and 'response' in parsed:
            return parsed
    except (json.JSONDecodeError, ValueError):
        pass

    # Try to find JSON in code blocks
    import re
    json_block = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL)
    if json_block:
        try:
            parsed = json.loads(json_block.group(1))
            if isinstance(parsed, dict) and 'response' in parsed:
                return parsed
        except (json.JSONDecodeError, ValueError):
            pass

    # Try to find a JSON object anywhere in the text
    brace_start = text.find('{')
    if brace_start >= 0:
        # Find the matching closing brace
        depth = 0
        for i in range(brace_start, len(text)):
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0:
                    try:
                        parsed = json.loads(text[brace_start:i + 1])
                        if isinstance(parsed, dict) and 'response' in parsed:
                            return parsed
                    except (json.JSONDecodeError, ValueError):
                        pass
                    break

    # Fallback: plain text response
    return {'response': text, 'script': '', 'questions': []}


# ---------------------------------------------------------------------------
# Script execution
# ---------------------------------------------------------------------------

def _execute_script(script):
    """Execute a multi-line PyMOL script silently on the main thread.

    Each non-empty, non-comment line is executed via _cmd.do(line, 0, 1).
    """
    if not script or not _cmd:
        return

    from pymol import ai_chat_ui
    for line in script.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            ai_chat_ui.run_on_main_thread(lambda l=line: _cmd.do(l, 0, 1))
        except Exception:
            pass  # silently ignore errors in script execution


# ---------------------------------------------------------------------------
# Anthropic streaming API
# ---------------------------------------------------------------------------

def _call_anthropic_streaming(messages, key, model,
                               on_content_block_start=None,
                               on_content_block_delta=None,
                               on_content_block_stop=None,
                               on_message_delta=None):
    """Call the Anthropic Messages API with streaming SSE.

    Reads the response line-by-line, parsing SSE events:
    - message_start
    - content_block_start: {content_block: {type, id?, name?}}
    - content_block_delta: {delta: {type: "text_delta"|"input_json_delta", ...}}
    - content_block_stop
    - message_delta: {delta: {stop_reason}}
    - message_stop
    """
    url = 'https://api.anthropic.com/v1/messages'

    payload = {
        'model': model,
        'max_tokens': 4096,
        'stream': True,
        'system': SYSTEM_PROMPT,
        'messages': messages,
    }

    # Include tools if available
    if TOOL_DEFINITIONS:
        payload['tools'] = TOOL_DEFINITIONS

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
        resp = urllib.request.urlopen(req, timeout=120)
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Anthropic HTTP {exc.code}: {error_body}") from exc

    try:
        _parse_sse_stream(resp, on_content_block_start, on_content_block_delta,
                          on_content_block_stop, on_message_delta)
    finally:
        resp.close()


def _parse_sse_stream(resp, on_content_block_start, on_content_block_delta,
                       on_content_block_stop, on_message_delta):
    """Parse an SSE stream from the Anthropic API response."""
    event_type = None
    data_buf = ''

    for raw_line in resp:
        line = raw_line.decode('utf-8', errors='replace').rstrip('\n').rstrip('\r')

        if line.startswith('event: '):
            event_type = line[7:].strip()
            data_buf = ''
            continue

        if line.startswith('data: '):
            data_buf += line[6:]
            continue

        if line == '' and event_type and data_buf:
            # End of event — process it
            try:
                payload = json.loads(data_buf)
            except json.JSONDecodeError:
                event_type = None
                data_buf = ''
                continue

            if event_type == 'content_block_start':
                block = payload.get('content_block', {})
                if on_content_block_start:
                    on_content_block_start(block)

            elif event_type == 'content_block_delta':
                delta = payload.get('delta', {})
                if on_content_block_delta:
                    on_content_block_delta(delta)

            elif event_type == 'content_block_stop':
                if on_content_block_stop:
                    on_content_block_stop()

            elif event_type == 'message_delta':
                delta = payload.get('delta', {})
                if on_message_delta:
                    on_message_delta(delta)

            elif event_type == 'message_stop':
                pass  # stream complete

            event_type = None
            data_buf = ''


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def clear_conversation():
    """Reset the conversation history and clear the UI (if available)."""
    global _messages
    _messages = []
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.clear_messages()
