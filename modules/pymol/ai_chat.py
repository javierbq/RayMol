"""AI Chat conversation engine for PyMOL — agentic LLM integration.

Uses the Claude Agent SDK when available for an agentic loop with MCP tools
and structured output. Falls back to hand-rolled urllib API calls if the SDK
is not installed.
"""

import os
import json
import threading
import asyncio

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
# Module state
# ---------------------------------------------------------------------------

_cmd = None
_has_ui = False
_ui = None  # the bound UI sink module (ai_chat_ui on AppKit, ai_chat_swift in-app)
_messages = []  # list of {'role': str, 'content': str | list}

# When the embedding sets PYMOL_AI_SINK=swift (the SwiftUI/Metal app, incl. iOS),
# force the headless print()-based sink AND the urllib HTTP path: the embedded
# interpreter cannot run the claude_agent_sdk subprocess, so the in-app path must
# be the hand-rolled Messages API call.
_FORCE_SWIFT_SINK = (os.environ.get('PYMOL_AI_SINK', '').lower() == 'swift')
if _FORCE_SWIFT_SINK:
    _HAS_SDK = False
    import urllib.request  # noqa: F401  (ensure fallback deps are available)
    import urllib.error    # noqa: F401

_ai_config = {
    'provider': 'anthropic',
    'api_keys': {
        'anthropic': os.environ.get('ANTHROPIC_API_KEY', ''),
        # Vertex bearer credential (GCP access token or Vertex API key).
        'vertex': os.environ.get('VERTEX_API_KEY', ''),
    },
    'models': {
        'anthropic': 'claude-sonnet-4-6',
        # Vertex publisher model id (note the @version suffix — Vertex-specific).
        'vertex': 'claude-sonnet-4-5@20250929',
    },
    # Vertex AI (Claude-on-Vertex) target: GCP project + region. The model lives
    # in the URL, not the body (see _call_vertex).
    'vertex': {
        'project': os.environ.get('VERTEX_PROJECT', ''),
        'region': os.environ.get('VERTEX_REGION', '') or 'us-east5',
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
    global _cmd, _has_ui, _ui

    _cmd = cmd_module

    # Re-read env vars (may have been set from ~/.pymol_ai.conf after module load)
    _ai_config['provider'] = os.environ.get('PYMOL_LLM_PROVIDER', _ai_config['provider'])
    for provider in _ai_config['api_keys']:
        env_key = provider.upper() + '_API_KEY'
        val = os.environ.get(env_key, '')
        if val:
            _ai_config['api_keys'][provider] = val

    # Vertex AI project/region (analogous per-provider env seeding).
    _vertex_project = os.environ.get('VERTEX_PROJECT', '')
    if _vertex_project:
        _ai_config['vertex']['project'] = _vertex_project
    _vertex_region = os.environ.get('VERTEX_REGION', '')
    if _vertex_region:
        _ai_config['vertex']['region'] = _vertex_region

    # Bind a UI sink. In the SwiftUI/Metal app (PYMOL_AI_SINK=swift, incl. iOS
    # which has no AppKit) use the headless print()-tag sink; otherwise prefer
    # the AppKit panel (ai_chat_ui) and fall back to the headless sink if PyObjC
    # / AppKit is unavailable.
    _ui = None
    _has_ui = False
    if _FORCE_SWIFT_SINK:
        try:
            from pymol import ai_chat_swift as _sink
            _ui = _sink
        except ImportError:
            _ui = None
    else:
        try:
            from pymol import ai_chat_ui as _sink
            _ui = _sink
        except ImportError:
            try:
                from pymol import ai_chat_swift as _sink
                _ui = _sink
            except ImportError:
                _ui = None

    if _ui is not None:
        _has_ui = True
        try:
            _ui._init()
        except Exception:
            pass

    cmd_module.extend('ai_config', ai_config)


def set_api_key(key, provider='anthropic'):
    """Set the API key for *provider* (default anthropic) at runtime.

    Used by the SwiftUI app to deliver the user's Keychain-stored key to the
    backend after init. Also mirrors it into os.environ so any code path that
    re-reads ANTHROPIC_API_KEY (and the SDK, if ever present) sees it.
    """
    global _ai_config
    key = (key or '').strip()
    _ai_config['api_keys'][provider] = key
    if provider == 'anthropic' and key:
        os.environ['ANTHROPIC_API_KEY'] = key


def set_provider(name):
    """Set the active LLM provider ('anthropic' or 'vertex').

    Called by the SwiftUI app's AI settings when the user picks a provider.
    Unknown names are ignored (the previous provider stays active) so a typo
    can't silently break the chat.
    """
    global _ai_config
    name = (name or '').strip().lower()
    if name in ('anthropic', 'vertex'):
        _ai_config['provider'] = name


def set_vertex_config(project, region, model=None):
    """Set the Vertex AI target (GCP project + region), and optionally the model.

    The bearer credential (GCP access token or Vertex API key) is delivered
    separately via set_api_key(token, 'vertex'). Used by the SwiftUI app to push
    the user's Keychain-stored Vertex settings to the backend after init.
    """
    global _ai_config
    _ai_config['vertex']['project'] = (project or '').strip()
    region = (region or '').strip()
    if region:
        _ai_config['vertex']['region'] = region
    if model:
        _ai_config['models']['vertex'] = model.strip()


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
        if provider == 'vertex':
            vx = _ai_config.get('vertex', {})
            print(f"  project  : {vx.get('project') or '(not set)'}")
            print(f"  region   : {vx.get('region') or '(not set)'}")
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
    if _has_ui and _ui is not None:
        _ui.toggle()
    else:
        print("Chat panel requires macOS with pyobjc-framework-Cocoa.")


def _on_user_message(text):
    """Main entry point called by the UI when the user submits a message."""
    global _messages

    _messages.append({'role': 'user', 'content': text})

    if _has_ui and _ui is not None:
        _ui.show_message('user', text)
        _ui.show_status('Thinking...')

    # Pre-flight credential check for the ACTIVE provider. The worker does a
    # deeper per-provider validation, but blocking here avoids starting a
    # doomed background thread and gives an immediate, provider-correct error.
    provider = _ai_config.get('provider', 'anthropic')
    if provider == 'vertex':
        cred = _ai_config['api_keys'].get('vertex', '')
        error_msg = (
            "No Vertex access token set. Open AI settings and paste a GCP access "
            "token (gcloud auth print-access-token) or a Vertex API key. "
            "(Access tokens expire ~1h.)"
        )
    else:
        cred = _ai_config['api_keys'].get('anthropic', '')
        error_msg = (
            "No API key set. "
            "Paste your Anthropic API key in Settings (stored in the Keychain), "
            "or run: ai_config key=YOUR_ANTHROPIC_API_KEY"
        )
    if not cred:
        if _has_ui and _ui is not None:
            _ui.show_message('error', error_msg)
            _ui.show_status('')
            _ui.set_busy(False)
        else:
            print(error_msg)
        return

    global _worker_active
    if _worker_active:
        if _has_ui and _ui is not None:
            _ui.show_message('assistant', 'Still processing the previous request...')
        return
    _worker_active = True
    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def clear_conversation():
    """Reset the conversation history and clear the UI (if available)."""
    global _messages
    _messages = []
    if _has_ui and _ui is not None:
        _ui.clear_messages()


_worker_active = False

# ---------------------------------------------------------------------------
# Worker dispatch — SDK path or fallback
# ---------------------------------------------------------------------------

def _worker():
    """Background thread: dispatch to SDK or fallback worker."""
    global _worker_active
    if _has_ui and _ui is not None:
        _ui.set_busy(True)
    try:
        # The Claude Agent SDK path only speaks Anthropic (x-api-key); Vertex
        # must use the urllib fallback (:rawPredict + Bearer). Route by the
        # active provider, not just SDK availability.
        provider = _ai_config.get('provider', 'anthropic')
        if _HAS_SDK and provider == 'anthropic':
            _worker_impl_sdk()
        else:
            _worker_impl_fallback()
    finally:
        _worker_active = False
        if _has_ui and _ui is not None:
            _ui.set_busy(False)


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
        if _has_ui and _ui is not None:
            _ui.update_on_main_thread(None, None, None, status=text)

    def _ui_msg(role, text):
        if _has_ui and _ui is not None:
            _ui.update_on_main_thread(role, text, [])

    try:
        # Ensure ANTHROPIC_API_KEY is set in the environment for the SDK
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
                "mcp__pymol__run_python",
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
        questions = parsed.get('questions', [])

        # Store assistant response in conversation history
        _messages.append({'role': 'assistant', 'content': [
            {'type': 'text', 'text': json.dumps(parsed)}
        ]})

        # Final UI update with the structured response text. All actions are
        # performed through the run_python tool during the agentic loop above;
        # there is no "script" field to execute here.
        _ui_msg('assistant', response_text)

        if questions and _has_ui and _ui is not None:
            _ui.show_question_buttons(questions)

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
        if _has_ui and _ui is not None:
            _ui.show_status(text)

    def _ui_msg(role, text):
        if _has_ui and _ui is not None:
            _ui.update_on_main_thread(role, text, [])

    try:
        provider = _ai_config.get('provider', 'anthropic')

        # Vertex AI (Claude-on-Vertex) requires project + region + a bearer
        # credential. Surface a clear error (like the no-key path) if any is
        # missing rather than firing a doomed request.
        if provider == 'vertex':
            token = _ai_config['api_keys'].get('vertex', '')
            model = _ai_config['models'].get('vertex', '')
            project = _ai_config['vertex'].get('project', '')
            region = _ai_config['vertex'].get('region', '')
            missing = [n for n, v in (('project', project), ('region', region),
                                      ('access token / API key', token)) if not v]
            if missing:
                _ui_msg('error',
                        "Vertex AI is selected but " + ", ".join(missing)
                        + " is not set. Open AI settings (the key icon in the "
                          "top-right of the chat) and fill in the Vertex Project "
                          "ID, Region, and access token.")
                _ui_status('')
                return
        else:
            key = _ai_config['api_keys'].get('anthropic', '')
            model = _ai_config['models'].get('anthropic', '')
            if not key:
                _ui_msg('error',
                        "No Anthropic API key set. Open AI settings (the key icon "
                        "in the top-right of the chat) and paste your Anthropic API "
                        "key, or run: ai_config key=YOUR_ANTHROPIC_API_KEY")
                _ui_status('')
                return

        # Working message list for THIS turn. Seeded from the clean cross-turn
        # history (text only) + the just-added user message, then extended with
        # raw tool_use/tool_result blocks DURING the loop. Keeping those blocks
        # intact within the turn is essential: the old code rebuilt the list every
        # round and stripped them, so the model never saw that a tool had run and
        # kept re-issuing the same call until the cap, then exited with NOTHING
        # shown. Only a clean text summary is committed to _messages at the end.
        turn_messages = _build_api_messages()

        max_tool_rounds = 8
        py_errors = []          # run_python tracebacks/errors, surfaced to the user
        tool_calls_made = 0     # how many tools actually ran this turn
        retried_empty = False   # have we already retried after an empty first turn?
        for _round in range(max_tool_rounds):
            try:
                if provider == 'vertex':
                    body = _call_vertex(turn_messages, token, model, project, region)
                else:
                    body = _call_anthropic(turn_messages, key, model)
            except Exception as exc:
                _ui_msg('error', f"API call failed: {exc}")
                _ui_status('')
                return

            stop_reason = body.get('stop_reason', 'end_turn')
            content = body.get('content', [])

            # Extract text and tool_use blocks
            text_parts = []
            tool_uses = []
            for block in content:
                if block.get('type') == 'text':
                    text_parts.append(block.get('text', ''))
                elif block.get('type') == 'tool_use':
                    tool_uses.append(block)
            full_text = ''.join(text_parts)

            # Keep the assistant turn (with its tool_use blocks) in the working
            # list so the next request carries tool context — Anthropic requires
            # each tool_use to be immediately followed by its tool_result.
            turn_messages.append({'role': 'assistant', 'content': content})

            # tool_use — run each tool, feed results back, loop again.
            if stop_reason == 'tool_use' and tool_uses:
                _ui_status('Working...')
                tool_results = []
                for tu in tool_uses:
                    tool_calls_made += 1
                    try:
                        result = execute_tool(tu['name'], tu['input'], _cmd)
                    except Exception as exc:
                        result = json.dumps({"error": str(exc)})
                    result_str = result if isinstance(result, str) else json.dumps(result)
                    # Surface run_python failures/tracebacks to the user, not just
                    # the model: the code now IS the action channel, so a raised
                    # exception is what the user would otherwise see as "nothing
                    # happened". Capture the traceback summary line.
                    if tu.get('name') == 'run_python' and 'Traceback' in result_str:
                        # The last non-empty line of a traceback is the exception.
                        tb_lines = [ln for ln in result_str.splitlines() if ln.strip()]
                        if tb_lines:
                            py_errors.append(tb_lines[-1].strip())
                    tool_results.append({
                        'type': 'tool_result',
                        'tool_use_id': tu['id'],
                        'content': result_str,
                    })
                turn_messages.append({'role': 'user', 'content': tool_results})
                continue  # next round

            # Final turn (end_turn / max_tokens / etc.) — parse and display.
            parsed = _parse_structured_response(full_text)
            response_text = (parsed.get('response') or '').strip()
            questions = parsed.get('questions', [])

            # Empty turn on the FIRST round (no tool call, no prose, no question):
            # the model returned nothing actionable. Retry ONCE with a brief nudge
            # before giving up, instead of emitting a misleading "nothing to do".
            if (not tool_calls_made and not response_text and not questions
                    and not retried_empty):
                retried_empty = True
                turn_messages.append({
                    'role': 'user',
                    'content': (
                        "Perform the request by calling run_python, or ask a "
                        "clarifying question — do not return an empty reply."
                    ),
                })
                continue  # give it one more round

            # Never leave a silent empty bubble.
            if not response_text and not questions:
                if tool_calls_made:
                    response_text = "Done."
                else:
                    response_text = ("I'm not sure how to act on that yet — could "
                                     "you rephrase or add a bit more detail?")

            if response_text:
                _ui_msg('assistant', response_text)

            if py_errors:
                shown = "\n".join("- " + e for e in py_errors[:6])
                extra = "" if len(py_errors) <= 6 else f"\n...and {len(py_errors) - 6} more"
                _ui_msg('error', "Some Python steps raised errors:\n" + shown + extra)

            if questions and _has_ui and _ui is not None:
                _ui.show_question_buttons(questions)

            # Commit a clean, text-only summary to the long-term conversation so
            # the next user turn has context without replaying tool blocks.
            _messages.append({'role': 'assistant',
                              'content': response_text or '(performed actions)'})
            _ui_status('')
            return

        # Round cap hit while still calling tools — don't exit silently.
        _ui_msg('assistant',
                "I worked through several steps but couldn't finish within the "
                "limit. Want me to keep going?")
        _messages.append({'role': 'assistant', 'content': '(step limit reached)'})
        _ui_status('')

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

    return cleaned


def _parse_structured_response(text):
    """Extract JSON {response, questions} from the model's text.

    The model is instructed to respond with JSON. This function tries to
    extract it, with a fallback to treating the entire text as a plain
    response (no questions).
    """
    text = text.strip()

    # Try direct JSON parse. strict=False allows literal control chars (real
    # newlines/tabs) inside strings, which the model occasionally emits inside
    # the `response` text and which would otherwise fail the parse.
    try:
        parsed = json.loads(text, strict=False)
        if isinstance(parsed, dict) and 'response' in parsed:
            return parsed
    except (json.JSONDecodeError, ValueError):
        pass

    # Try to find JSON in code blocks
    import re
    json_block = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL)
    if json_block:
        try:
            parsed = json.loads(json_block.group(1), strict=False)
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
                        parsed = json.loads(text[brace_start:i + 1], strict=False)
                        if isinstance(parsed, dict) and 'response' in parsed:
                            return parsed
                    except (json.JSONDecodeError, ValueError):
                        pass
                    break

    # Fallback: plain text response
    return {'response': text, 'questions': []}


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


# ---------------------------------------------------------------------------
# Fallback Vertex AI (Claude-on-Vertex) call (urllib, no SDK)
# ---------------------------------------------------------------------------

def _call_vertex(messages, token, model, project, region):
    """Call Claude on Google Cloud Vertex AI (rawPredict). Returns the body dict.

    The response shape is identical to the Anthropic Messages API (content
    blocks / stop_reason / tool_use), so the worker's parsing is unchanged.

    Differences from _call_anthropic:
      - model lives in the URL (publisher path), NOT the JSON body;
      - the body adds "anthropic_version": "vertex-2023-10-16";
      - auth is a Bearer token (a GCP access token, typically from
        `gcloud auth print-access-token`, or a Vertex API key) — there is no
        x-api-key and no anthropic-version header.
    """
    # The 'global' endpoint has NO region prefix in the host; regional
    # locations (us-east5, europe-west1, ...) do.
    host = ('aiplatform.googleapis.com' if region == 'global'
            else f'{region}-aiplatform.googleapis.com')
    url = (
        f'https://{host}/v1/projects/{project}'
        f'/locations/{region}/publishers/anthropic/models/{model}:rawPredict'
    )

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
        raise RuntimeError(f"Vertex HTTP {exc.code}: {error_body}") from exc
