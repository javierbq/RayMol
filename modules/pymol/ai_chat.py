"""AI Chat conversation engine for PyMOL — agentic LLM integration.

Uses the Claude Agent SDK when available for an agentic loop with MCP tools
and structured output. Falls back to hand-rolled urllib API calls if the SDK
is not installed.
"""

import os
import json
import subprocess
import threading
import asyncio
import time

def _log(msg):
    """Print timestamped telemetry to stderr."""
    import sys
    t = time.strftime('%H:%M:%S')
    ms = int((time.time() % 1) * 1000)
    print(f'[ai_chat {t}.{ms:03d}] {msg}', file=sys.stderr, flush=True)

# ---------------------------------------------------------------------------
# SDK availability check
# ---------------------------------------------------------------------------

try:
    from claude_agent_sdk import (
        query,
        ClaudeAgentOptions,
        AssistantMessage,
        ResultMessage,
        TextBlock,
    )
    _HAS_SDK = True
except ImportError:
    _HAS_SDK = False

# Fallback imports (only needed when SDK is unavailable)
if not _HAS_SDK:
    import urllib.request
    import urllib.error

# ---------------------------------------------------------------------------
# Keychain helpers (macOS)
# ---------------------------------------------------------------------------

_KEYCHAIN_SERVICE = 'com.pymol.ai-chat'
_KEYCHAIN_ACCOUNT = 'anthropic-api-key'
_KEYCHAIN_ACCOUNT_PROVIDER = 'provider'
_KEYCHAIN_ACCOUNT_VERTEX_SA = 'vertex-sa-json-path'
_KEYCHAIN_ACCOUNT_VERTEX_PROJECT = 'vertex-project-id'
_KEYCHAIN_ACCOUNT_VERTEX_REGION = 'vertex-region'


def _keychain_get(account=_KEYCHAIN_ACCOUNT):
    """Retrieve a value from the macOS Keychain. Returns '' on failure."""
    try:
        result = subprocess.run(
            ['security', 'find-generic-password',
             '-s', _KEYCHAIN_SERVICE, '-a', account, '-w'],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ''


def _keychain_set(value, account=_KEYCHAIN_ACCOUNT):
    """Store a value in the macOS Keychain."""
    try:
        subprocess.run(
            ['security', 'delete-generic-password',
             '-s', _KEYCHAIN_SERVICE, '-a', account],
            capture_output=True, timeout=5,
        )
        subprocess.run(
            ['security', 'add-generic-password',
             '-s', _KEYCHAIN_SERVICE, '-a', account,
             '-w', value],
            capture_output=True, check=True, timeout=5,
        )
        return True
    except Exception:
        return False


def _keychain_delete(account=_KEYCHAIN_ACCOUNT):
    """Remove a value from the macOS Keychain."""
    try:
        subprocess.run(
            ['security', 'delete-generic-password',
             '-s', _KEYCHAIN_SERVICE, '-a', account],
            capture_output=True, timeout=5,
        )
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

_cmd = None
_has_ui = False
_messages = []  # list of {'role': str, 'content': str | list}

_ai_config = {
    'provider': os.environ.get('PYMOL_LLM_PROVIDER', 'anthropic'),
    'api_keys': {
        'anthropic': os.environ.get('ANTHROPIC_API_KEY', ''),
    },
    'models': {
        'anthropic': 'claude-sonnet-4-6',
        'vertex_ai': 'claude-sonnet-4-6',
    },
    'vertex_ai': {
        'project_id': os.environ.get('GCP_PROJECT_ID', ''),
        'region': os.environ.get('GCP_REGION', 'us-east5'),
        'sa_json_data': '',  # raw SA JSON string (loaded from Keychain)
    },
}

from pymol.ai_system_prompt import SYSTEM_PROMPT

# Try to import tool definitions (fallback path) and MCP server (SDK path)
try:
    from pymol.ai_tools import TOOL_DEFINITIONS, execute_tool
except ImportError:
    TOOL_DEFINITIONS = []
    def execute_tool(name, tool_input, cmd):
        return json.dumps({"error": f"Tool '{name}' not available — ai_tools module not found."})

try:
    from pymol.ai_tools import pymol_server
except ImportError:
    pymol_server = None

# ---------------------------------------------------------------------------
# Structured output schema for the Claude Agent SDK
# ---------------------------------------------------------------------------

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "response": {"type": "string"},
        "script": {"type": "string"},
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "type": {
                        "type": "string",
                        "enum": ["single", "multiple"],
                        "description": "single: pick one option (radio). multiple: pick several (checkboxes + submit).",
                    },
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                    },
                },
                "required": ["text", "options"],
            },
        },
    },
    "required": ["response"],
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

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

    # Load saved provider preference from keychain
    saved_provider = _keychain_get(_KEYCHAIN_ACCOUNT_PROVIDER)
    if saved_provider in ('anthropic', 'vertex_ai'):
        _ai_config['provider'] = saved_provider

    # If no API key from env, try the macOS Keychain
    if not _ai_config['api_keys'].get('anthropic'):
        keychain_key = _keychain_get(_KEYCHAIN_ACCOUNT)
        if keychain_key:
            _ai_config['api_keys']['anthropic'] = keychain_key

    # Load Vertex AI SA credentials from keychain (base64-encoded JSON)
    if not _ai_config['vertex_ai'].get('sa_json_data'):
        sa_encoded = _keychain_get(_KEYCHAIN_ACCOUNT_VERTEX_SA)
        if sa_encoded:
            import base64
            try:
                _ai_config['vertex_ai']['sa_json_data'] = base64.b64decode(sa_encoded).decode('utf-8')
            except Exception:
                _ai_config['vertex_ai']['sa_json_data'] = ''
    if not _ai_config['vertex_ai']['project_id']:
        project = _keychain_get(_KEYCHAIN_ACCOUNT_VERTEX_PROJECT)
        if project:
            _ai_config['vertex_ai']['project_id'] = project
    region = _keychain_get(_KEYCHAIN_ACCOUNT_VERTEX_REGION)
    if region:
        _ai_config['vertex_ai']['region'] = region

    try:
        from pymol import ai_chat_ui
        _has_ui = True
        ai_chat_ui._init()
    except ImportError:
        _has_ui = False

    cmd_module.extend('ai_config', ai_config)

    # Eagerly import ai_vertex_auth so the cryptography library loads during
    # startup (takes ~20s on first load) rather than blocking the first chat message.
    if _ai_config['provider'] == 'vertex_ai':
        try:
            import pymol.ai_vertex_auth  # noqa: F401
        except ImportError:
            pass

    # If no credentials for the active provider, prompt the user
    if _has_ui and not _has_credentials():
        from pymol import ai_chat_ui
        ai_chat_ui.prompt_for_credentials()


def _has_credentials():
    """Return True if the active provider has credentials configured."""
    provider = _ai_config['provider']
    if provider == 'anthropic':
        return bool(_ai_config['api_keys'].get('anthropic', ''))
    elif provider == 'vertex_ai':
        vc = _ai_config['vertex_ai']
        return bool(vc.get('project_id') and vc.get('sa_json_data'))
    return False


def _vertex_gcloud_available():
    """Check if gcloud CLI is available for Vertex AI auth."""
    try:
        r = subprocess.run(['gcloud', 'auth', 'print-access-token'],
                           capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False


def set_api_key(key):
    """Set the Anthropic API key, storing it in the Keychain."""
    _ai_config['api_keys']['anthropic'] = key
    _ai_config['provider'] = 'anthropic'
    _keychain_set(key, _KEYCHAIN_ACCOUNT)
    _keychain_set('anthropic', _KEYCHAIN_ACCOUNT_PROVIDER)


def set_vertex_config(sa_json_path, project_id, region='us-east5'):
    """Configure Vertex AI credentials, storing in Keychain.

    Reads the SA JSON file, base64-encodes its contents, and stores the
    encoded blob in the Keychain so the app never needs the file again.
    """
    import base64
    with open(sa_json_path) as f:
        sa_raw = f.read()
    encoded = base64.b64encode(sa_raw.encode('utf-8')).decode('ascii')

    _ai_config['provider'] = 'vertex_ai'
    _ai_config['vertex_ai']['sa_json_data'] = sa_raw
    _ai_config['vertex_ai']['project_id'] = project_id
    _ai_config['vertex_ai']['region'] = region
    _keychain_set('vertex_ai', _KEYCHAIN_ACCOUNT_PROVIDER)
    _keychain_set(encoded, _KEYCHAIN_ACCOUNT_VERTEX_SA)
    _keychain_set(project_id, _KEYCHAIN_ACCOUNT_VERTEX_PROJECT)
    _keychain_set(region, _KEYCHAIN_ACCOUNT_VERTEX_REGION)
    # Clear token cache
    try:
        from pymol.ai_vertex_auth import clear_cache
        clear_cache()
    except ImportError:
        pass


def logout():
    """Clear credentials for the active provider."""
    provider = _ai_config['provider']
    if provider == 'anthropic':
        _ai_config['api_keys']['anthropic'] = ''
        _keychain_delete(_KEYCHAIN_ACCOUNT)
    elif provider == 'vertex_ai':
        _ai_config['vertex_ai']['sa_json_data'] = ''
        _ai_config['vertex_ai']['project_id'] = ''
        _keychain_delete(_KEYCHAIN_ACCOUNT_VERTEX_SA)
        _keychain_delete(_KEYCHAIN_ACCOUNT_VERTEX_PROJECT)
        _keychain_delete(_KEYCHAIN_ACCOUNT_VERTEX_REGION)
        try:
            from pymol.ai_vertex_auth import clear_cache
            clear_cache()
        except ImportError:
            pass
    _keychain_delete(_KEYCHAIN_ACCOUNT_PROVIDER)
    clear_conversation()
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.show_message('assistant', 'Credentials removed. You have been logged out.')


def get_masked_key():
    """Return a masked version of the current API key for display."""
    key = _ai_config['api_keys'].get('anthropic', '')
    if len(key) > 12:
        return key[:8] + '...' + key[-4:]
    elif key:
        return '***'
    return ''


def is_logged_in():
    """Return True if the active provider has credentials."""
    return _has_credentials()


def get_provider():
    """Return the active provider name."""
    return _ai_config['provider']


def ai_config(args='', _self=None):
    """Show or set AI provider configuration.

    Usage:
        ai_config                        # show current config
        ai_config key=sk-...             # set API key
        ai_config model=claude-sonnet-4-6  # set model
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
        print(f"  sdk      : {'claude-agent-sdk' if _HAS_SDK else 'urllib (fallback)'}")
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
    _log(f'_on_user_message: "{text[:50]}"')

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

    global _worker_active
    if _worker_active:
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.show_message('assistant', 'Still processing the previous request...')
        return
    _worker_active = True
    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def clear_conversation():
    """Reset the conversation history and clear the UI (if available)."""
    global _messages
    _messages = []
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.clear_messages()


_worker_active = False

# ---------------------------------------------------------------------------
# Worker dispatch — SDK path or fallback
# ---------------------------------------------------------------------------

def _worker():
    """Background thread: dispatch to SDK or fallback worker."""
    global _worker_active
    _log(f'_worker started, _HAS_SDK={_HAS_SDK}, provider={_ai_config["provider"]}')
    if _has_ui:
        from pymol import ai_chat_ui
        ai_chat_ui.set_busy(True)
    try:
        if _HAS_SDK:
            _log('dispatching to SDK worker')
            _worker_impl_sdk()
        else:
            _log('dispatching to fallback worker')
            _worker_impl_fallback()
    finally:
        _worker_active = False
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.set_busy(False)


# ---------------------------------------------------------------------------
# SDK-based worker (claude-agent-sdk)
# ---------------------------------------------------------------------------

def _worker_impl_sdk():
    """Worker using the Claude Agent SDK with MCP tools and structured output."""
    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(_agent_query())
    finally:
        loop.close()


async def _agent_query():
    """Async function that runs the Claude Agent SDK query."""
    global _messages

    def _ui_status(text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_on_main_thread(None, None, None, status=text)

    def _ui_msg(role, text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_on_main_thread(role, text, [])

    try:
        # Set environment variables for the SDK based on active provider
        provider = _ai_config['provider']
        if provider == 'vertex_ai':
            vc = _ai_config['vertex_ai']
            os.environ['CLOUD_ML_REGION'] = vc.get('region', 'us-east5')
            os.environ['ANTHROPIC_VERTEX_PROJECT_ID'] = vc.get('project_id', '')
            sa_data = vc.get('sa_json_data', '')
            if sa_data:
                import tempfile
                tmp = tempfile.NamedTemporaryFile(
                    mode='w', suffix='.json', prefix='aimol_sa_', delete=False)
                tmp.write(sa_data)
                tmp.close()
                os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = tmp.name
        else:
            key = _ai_config['api_keys'].get('anthropic', '')
            if key:
                os.environ['ANTHROPIC_API_KEY'] = key

        # Build the prompt from the last user message
        user_text = ''
        for m in reversed(_messages):
            if m['role'] == 'user' and isinstance(m['content'], str):
                user_text = m['content']
                break

        # Build conversation context from history (excluding the last user msg)
        # The SDK manages its own conversation, but we provide context as part
        # of the prompt so it knows about prior exchanges.
        context_parts = []
        for m in _messages[:-1]:
            role = m['role']
            content = m['content']
            if isinstance(content, str) and content.strip():
                context_parts.append(f"{role}: {content}")
            elif isinstance(content, list):
                text_parts = []
                for block in content:
                    if isinstance(block, dict) and block.get('type') == 'text':
                        text_parts.append(block.get('text', ''))
                joined = '\n'.join(text_parts).strip()
                if joined:
                    context_parts.append(f"{role}: {joined}")

        prompt = user_text
        if context_parts:
            context_str = '\n'.join(context_parts)
            prompt = (
                f"<conversation_history>\n{context_str}\n"
                f"</conversation_history>\n\n{user_text}"
            )

        # Configure MCP servers
        mcp_servers = {}
        if pymol_server is not None:
            mcp_servers["pymol"] = pymol_server

        # Configure allowed tools
        allowed_tools = []
        if pymol_server is not None:
            allowed_tools = [
                "mcp__pymol__get_session_state",
                "mcp__pymol__execute_command",
                "mcp__pymol__capture_viewport",
                "mcp__pymol__search_pdb",
            ]

        options = ClaudeAgentOptions(
            system_prompt=SYSTEM_PROMPT,
            mcp_servers=mcp_servers if mcp_servers else None,
            allowed_tools=allowed_tools if allowed_tools else None,
            output_format={"type": "json_schema", "schema": RESPONSE_SCHEMA},
        )

        streaming_text = []
        result_data = None

        async for message in query(prompt=prompt, options=options):
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        streaming_text.append(block.text)
                        # Don't show streaming text — we show the final
                        # parsed response after the query completes.

            elif isinstance(message, ResultMessage):
                if message.subtype == "success":
                    result_data = message.structured_output

        # Process the result
        if result_data and isinstance(result_data, dict):
            parsed = result_data
        else:
            # Fallback: try to parse from the accumulated streaming text
            full_text = ''.join(streaming_text)
            parsed = _parse_structured_response(full_text)

        response_text = parsed.get('response', ''.join(streaming_text) or '(no response)')
        script = parsed.get('script', '')
        questions = parsed.get('questions', [])

        # Store assistant response in conversation history
        _messages.append({'role': 'assistant', 'content': [
            {'type': 'text', 'text': json.dumps(parsed)}
        ]})

        # Final UI update with the structured response text
        _ui_msg('assistant', response_text)

        if script:
            _ui_status('Executing...')
            _execute_script(script)

        if questions and _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.show_question_buttons(questions)

        _ui_status('')

    except Exception as exc:
        _ui_msg('error', f"SDK error: {exc}")
        _ui_status('')


# ---------------------------------------------------------------------------
# Fallback worker (urllib, no SDK)
# ---------------------------------------------------------------------------

def _worker_impl_fallback():
    """Simple non-streaming agentic loop using urllib (fallback when SDK is unavailable)."""
    global _messages

    def _ui_status(text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.show_status(text)

    def _ui_msg(role, text):
        if _has_ui:
            from pymol import ai_chat_ui
            ai_chat_ui.update_on_main_thread(role, text, [])

    try:
        provider = _ai_config['provider']
        model = _ai_config['models'].get(provider, 'claude-sonnet-4-6')
        _log(f'fallback worker: provider={provider}, model={model}')

        max_tool_rounds = 5
        # For the first round, build clean messages from conversation history.
        # For subsequent rounds (tool-use loop), send _messages directly so the
        # model can see its own tool_use blocks and tool_result responses.
        use_raw_messages = False
        for _round in range(max_tool_rounds):
            if use_raw_messages:
                _log(f'round {_round}: using raw messages (with tool blocks)')
                api_messages = _messages
            else:
                _log(f'round {_round}: building clean api messages')
                api_messages = _build_api_messages()
            _log(f'round {_round}: {len(api_messages)} messages, calling API...')

            try:
                t_api = time.time()
                if provider == 'vertex_ai':
                    body = _call_vertex_ai(api_messages, model)
                else:
                    key = _ai_config['api_keys'].get('anthropic', '')
                    body = _call_anthropic(api_messages, key, model)
                _log(f'round {_round}: API returned in {time.time()-t_api:.2f}s')
            except Exception as exc:
                _log(f'round {_round}: API FAILED in {time.time()-t_api:.2f}s: {exc}')
                _ui_msg('error', f"API call failed: {exc}")
                _ui_status('')
                return

            stop_reason = body.get('stop_reason', 'end_turn')
            content = body.get('content', [])
            _log(f'round {_round}: stop_reason={stop_reason}, content_blocks={len(content)}')

            # Extract text and tool_use blocks
            text_parts = []
            tool_uses = []
            for block in content:
                if block.get('type') == 'text':
                    text_parts.append(block.get('text', ''))
                elif block.get('type') == 'tool_use':
                    tool_uses.append(block)

            full_text = ''.join(text_parts)

            # Store in conversation history
            _messages.append({'role': 'assistant', 'content': content})

            # Handle tool_use
            if stop_reason == 'tool_use' and tool_uses:
                _ui_status('Using tools...')
                _log(f'round {_round}: executing {len(tool_uses)} tools: {[tu["name"] for tu in tool_uses]}')

                # Run tools in parallel when there are multiple
                if len(tool_uses) > 1:
                    _log(f'  running {len(tool_uses)} tools in parallel')
                    from concurrent.futures import ThreadPoolExecutor, as_completed

                    def _run_tool(tu):
                        t_tool = time.time()
                        try:
                            result = execute_tool(tu['name'], tu['input'], _cmd)
                        except Exception as exc:
                            result = json.dumps({"error": str(exc)})
                        _log(f'  tool: {tu["name"]} returned in {time.time()-t_tool:.2f}s ({len(str(result))} chars)')
                        return tu, result

                    tool_results_map = {}
                    with ThreadPoolExecutor(max_workers=len(tool_uses)) as pool:
                        futures = {pool.submit(_run_tool, tu): tu['id'] for tu in tool_uses}
                        for f in as_completed(futures):
                            tu, result = f.result()
                            tool_results_map[tu['id']] = result

                    tool_results = []
                    for tu in tool_uses:
                        result = tool_results_map[tu['id']]
                        result_str = result if isinstance(result, str) else json.dumps(result)
                        tool_results.append({
                            'type': 'tool_result',
                            'tool_use_id': tu['id'],
                            'content': result_str,
                        })
                else:
                    # Single tool — run directly
                    tool_results = []
                    for tu in tool_uses:
                        _log(f'  tool: {tu["name"]}({json.dumps(tu["input"])[:100]})')
                        t_tool = time.time()
                        try:
                            result = execute_tool(tu['name'], tu['input'], _cmd)
                        except Exception as exc:
                            result = json.dumps({"error": str(exc)})
                        _log(f'  tool: {tu["name"]} returned in {time.time()-t_tool:.2f}s ({len(str(result))} chars)')

                        result_str = result if isinstance(result, str) else json.dumps(result)
                        tool_results.append({
                            'type': 'tool_result',
                            'tool_use_id': tu['id'],
                            'content': result_str,
                        })

                _messages.append({'role': 'user', 'content': tool_results})
                use_raw_messages = True  # subsequent rounds must include tool blocks
                _ui_status('Thinking...')
                continue  # next round

            # end_turn — parse and display
            parsed = _parse_structured_response(full_text)
            response_text = parsed.get('response', full_text)
            script = parsed.get('script', '')
            questions = parsed.get('questions', [])

            _ui_msg('assistant', response_text)

            if script:
                _ui_status('Executing...')
                _execute_script(script)

            if questions and _has_ui:
                from pymol import ai_chat_ui
                ai_chat_ui.show_question_buttons(questions)

            _ui_status('')
            break

    except Exception as exc:
        _ui_msg('error', f"Unexpected error: {exc}")
        _ui_status('')


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _build_api_messages():
    """Build a clean message list for the Anthropic API (fallback path).

    Strips tool_use/tool_result blocks from conversation history since those
    are only valid within a single agentic loop turn. Keeps only text content
    for the persistent conversation context.
    """
    api_messages = []
    for m in _messages:
        role = m['role']
        content = m['content']

        # If content is a list of blocks (from a tool_use turn), extract text only
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict):
                    if block.get('type') == 'text':
                        text_parts.append(block.get('text', ''))
                    elif block.get('type') == 'tool_result':
                        continue
                    elif block.get('type') == 'tool_use':
                        continue
            text = '\n'.join(text_parts).strip()
            if not text:
                continue  # skip empty messages
            api_messages.append({'role': role, 'content': text})
        else:
            api_messages.append({'role': role, 'content': content})

    # Ensure proper alternating roles (Anthropic requires this)
    cleaned = []
    for msg in api_messages:
        if cleaned and cleaned[-1]['role'] == msg['role']:
            cleaned[-1]['content'] += '\n' + msg['content']
        else:
            cleaned.append(msg)

    # Vertex AI requires the conversation to end with a user message.
    # Trim any trailing assistant messages.
    while cleaned and cleaned[-1]['role'] == 'assistant':
        cleaned.pop()

    return cleaned


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


def _execute_script(script):
    """Execute a multi-line PyMOL script from the worker thread.

    Each non-empty, non-comment line is executed via _cmd.do(line, 0, 1).
    _cmd.do() is a C extension that acquires the PyMOL API lock internally
    (via APIEnterNotModal), so it is safe to call from any thread.  The
    worker thread holds the GIL while calling into _cmd.do(); the API lock
    serializes access to PyMOL's internal state against the render loop.
    """
    if not script or not _cmd:
        return

    for line in script.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            _cmd.do(line, 0, 1)
        except Exception:
            pass  # silently ignore errors in script execution


# ---------------------------------------------------------------------------
# Fallback Anthropic API call (urllib, no SDK)
# ---------------------------------------------------------------------------

def _call_anthropic(messages, key, model):
    """Call the Anthropic Messages API (non-streaming). Returns the response body dict.

    Only used when claude-agent-sdk is not installed.
    """
    url = 'https://api.anthropic.com/v1/messages'

    payload = {
        'model': model,
        'max_tokens': 4096,
        'system': SYSTEM_PROMPT,
        'messages': messages,
    }

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
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Anthropic HTTP {exc.code}: {error_body}") from exc


def _call_vertex_ai(messages, model):
    """Call Claude via Vertex AI (non-streaming). Returns the response body dict."""
    from pymol.ai_vertex_auth import get_access_token_from_data

    vc = _ai_config['vertex_ai']
    project_id = vc['project_id']
    region = vc['region']
    sa_data = vc.get('sa_json_data', '')

    _log('vertex: getting access token from keychain credentials...')
    t_tok = time.time()
    token = get_access_token_from_data(sa_data) if sa_data else ''
    _log(f'vertex: token obtained in {time.time()-t_tok:.2f}s')
    if not token:
        raise RuntimeError(
            "Could not obtain Vertex AI access token. "
            "Re-configure your service account via the account menu.")

    url = (
        f"https://{region}-aiplatform.googleapis.com/v1/"
        f"projects/{project_id}/locations/{region}/"
        f"publishers/anthropic/models/{model}:rawPredict"
    )

    # Vertex AI rawPredict: model is in the URL, NOT in the body.
    # system and tools are supported same as direct Anthropic API.
    payload = {
        'anthropic_version': 'vertex-2023-10-16',
        'max_tokens': 4096,
        'system': SYSTEM_PROMPT,
        'messages': messages,
    }

    if TOOL_DEFINITIONS:
        payload['tools'] = TOOL_DEFINITIONS

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {token}',
        },
        method='POST',
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Vertex AI HTTP {exc.code}: {error_body}") from exc
