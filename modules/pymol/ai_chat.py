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
        # Parsed service-account JSON (dict) for on-device token minting. When
        # set, _call_vertex mints a fresh, auto-refreshing access token from it
        # instead of using the manual api_keys['vertex'] bearer (which stays as
        # a fallback for users who paste a gcloud token). See ai_vertex_auth.
        'sa_key': None,
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


def set_vertex_sa_key(json_str):
    """Store a Google service-account JSON key for on-device token minting.

    *json_str* is the raw contents of the downloaded SA key file. We parse and
    stash the dict in _ai_config['vertex']['sa_key']; _call_vertex then mints a
    fresh, auto-refreshing Vertex access token from it (via ai_vertex_auth) for
    every request, so the user never has to paste short-lived gcloud tokens.

    Passing an empty string clears the stored key (falls back to the manual
    access-token field). A malformed JSON is reported but does NOT raise, so a
    bad paste can't break delivery of the rest of the AI settings.
    """
    global _ai_config
    json_str = (json_str or '').strip()
    if not json_str:
        _ai_config['vertex']['sa_key'] = None
        try:
            from pymol import ai_vertex_auth
            ai_vertex_auth.invalidate()
        except Exception:
            pass
        return
    try:
        info = json.loads(json_str)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"Vertex service-account JSON is not valid JSON: {exc}")
        return
    if not isinstance(info, dict) or 'private_key' not in info or 'client_email' not in info:
        print("Vertex service-account JSON is missing required fields "
              "('client_email', 'private_key').")
        return
    _ai_config['vertex']['sa_key'] = info
    # New credentials → drop any token cached from a previous SA key.
    try:
        from pymol import ai_vertex_auth
        ai_vertex_auth.invalidate()
    except Exception:
        pass


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
            sa = vx.get('sa_key')
            sa_desc = (f"on-device minting ({sa.get('client_email')})"
                       if isinstance(sa, dict) else '(not set)')
            print(f"  sa_key   : {sa_desc}")
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
        # A pasted service-account JSON (on-device minting) OR a manual access
        # token both count as a valid Vertex credential.
        cred = _ai_config['vertex'].get('sa_key') or _ai_config['api_keys'].get('vertex', '')
        error_msg = (
            "No Vertex credential set. Open AI settings and either paste a "
            "service-account JSON key (recommended — auto-mints + refreshes "
            "tokens on-device) or a GCP access token "
            "(gcloud auth print-access-token; expires ~1h)."
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
        # credential. The credential is either a pasted service-account JSON
        # (on-device minting, preferred) OR a manual access token. Surface a
        # clear error (like the no-key path) if any piece is missing rather than
        # firing a doomed request.
        if provider == 'vertex':
            token = _ai_config['api_keys'].get('vertex', '')
            sa_key = _ai_config['vertex'].get('sa_key')
            model = _ai_config['models'].get('vertex', '')
            project = _ai_config['vertex'].get('project', '')
            region = _ai_config['vertex'].get('region', '')
            have_cred = bool(sa_key) or bool(token)
            missing = [n for n, v in (('project', project), ('region', region),
                                      ('service-account JSON or access token', have_cred))
                       if not v]
            if missing:
                _ui_msg('error',
                        "Vertex AI is selected but " + ", ".join(missing)
                        + " is not set. Open AI settings and fill in the Vertex "
                          "Project ID, Region, and a credential (a service-account "
                          "JSON key, or an access token).")
                _ui_status('')
                return
        else:
            key = _ai_config['api_keys'].get('anthropic', '')
            model = _ai_config['models'].get('anthropic', '')

        # Working message list for THIS turn. Seeded from the clean cross-turn
        # history (text only) + the just-added user message, then extended with
        # raw tool_use/tool_result blocks DURING the loop. Keeping those blocks
        # intact within the turn is essential: the old code rebuilt the list every
        # round and stripped them, so the model never saw that a tool had run and
        # kept re-issuing the same call until the cap, then exited with NOTHING
        # shown. Only a clean text summary is committed to _messages at the end.
        turn_messages = _build_api_messages()

        max_tool_rounds = 8
        cmd_errors = []
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
                    try:
                        result = execute_tool(tu['name'], tu['input'], _cmd)
                    except Exception as exc:
                        result = json.dumps({"error": str(exc)})
                    result_str = result if isinstance(result, str) else json.dumps(result)
                    # Surface execute_command failures to the user, not just the model.
                    if tu.get('name') == 'execute_command':
                        for ln in result_str.splitlines():
                            if ln.startswith('Error:'):
                                cmd_errors.append(ln[len('Error:'):].strip())
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
            script = parsed.get('script', '')
            questions = parsed.get('questions', [])

            if script:
                _ui_status('Executing...')
                cmd_errors.extend(_execute_script(script))

            # Never leave a silent empty bubble: if there's no prose and no
            # question, acknowledge whatever ran (or that nothing did).
            if not response_text and not questions:
                response_text = "Done." if (script or _round > 0) \
                    else "I didn't have anything to do there — try rephrasing?"

            if response_text:
                _ui_msg('assistant', response_text)

            if cmd_errors:
                shown = "\n".join("- " + e for e in cmd_errors[:6])
                extra = "" if len(cmd_errors) <= 6 else f"\n...and {len(cmd_errors) - 6} more"
                _ui_msg('error', "Some commands didn't run cleanly:\n" + shown + extra)

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
    """Extract JSON {response, script, questions} from the model's text.

    The model is instructed to respond with JSON. This function tries to
    extract it, with a fallback to treating the entire text as a plain
    response (no script, no questions).
    """
    text = text.strip()

    # Try direct JSON parse. strict=False allows literal control chars (real
    # newlines/tabs) inside strings — the model often emits a real newline in
    # the `script` field instead of \n, which would otherwise fail the parse
    # and silently drop the action (the "replies but does nothing" symptom).
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
    return {'response': text, 'script': '', 'questions': []}


def _execute_script(script):
    """Execute a multi-line PyMOL script from the worker thread.

    Each non-empty, non-comment line runs via _cmd.do(line, 0, 1) — a C
    extension that takes the PyMOL API lock internally, so it is safe from the
    worker thread (the lock serializes against the render loop). Returns a list
    of human-readable error strings (empty when everything ran cleanly) so the
    caller can SURFACE failures to the user instead of silently swallowing them.
    """
    errors = []
    if not script or not _cmd:
        return errors

    # Drain stale feedback so we only attribute errors to THIS script.
    try:
        _cmd._get_feedback()
    except Exception:
        pass

    for line in script.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            _cmd.do(line, 0, 1)
        except Exception as exc:
            errors.append(f"{line} => {exc}")

    # PyMOL reports most command failures via the feedback buffer rather than
    # by raising, so scan it for error lines too.
    try:
        fb = _cmd._get_feedback()
        if fb:
            for item in fb:
                parts = item if isinstance(item, (list, tuple)) else [item]
                for s in parts:
                    if isinstance(s, str) and s.strip():
                        low = s.strip()
                        if 'error' in low.lower() or low.lower().startswith('selector'):
                            errors.append(low)
    except Exception:
        pass

    return errors


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

    If a service-account JSON key was pasted (_ai_config['vertex']['sa_key']),
    we mint a fresh, auto-refreshing access token from it on-device and use that
    as the Bearer; otherwise the manual *token* argument is used as a fallback.
    """
    # Prefer an on-device-minted token from a pasted service-account JSON.
    sa_key = _ai_config['vertex'].get('sa_key')
    if sa_key:
        from pymol import ai_vertex_auth
        token = ai_vertex_auth.mint(sa_key)
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
