"""The ColabFold MSA-server protocol: submit a ticket, poll it, take the tarball.

Checked against the server RayMol actually talks to, not only against ColabFold's
client. `deploy_colbfold_local` provisions a VM running ColabFold's own
`/opt/ColabFold/MsaServer/msa-server -local -config config.json`
(`startup-script.sh:22-40`), and that binary is MMseqs2-App's Go backend, whose routes
are declared in `backend/server.go`:

    POST /ticket/msa            form-encoded `q` (a FASTA) and `mode`
    GET  /ticket/{id}           {"id": ..., "status": ...}
    GET  /result/download/{id}  tar.gz of one a3m per searched database

The status vocabulary is `backend/jobsystem.go`'s: PENDING, RUNNING, COMPLETE, ERROR,
UNKNOWN. Two states from the sketch in ColabFold's client are NOT job states here and
would be missed by anything that only reads `status` off a 200:

  * RATELIMIT is the answer to the REQUEST, not to the job. tollbooth replies HTTP 429
    with `{"status":"RATELIMIT","reason":...}` (server.go, `RateLimitResponse`), so it
    arrives as an HTTPError and reads as a transport failure unless it is recognised
    there. On the public server this is the COMMON case, not an edge one.
  * MAINTENANCE comes from the public deployment's front end rather than from this
    backend, so it is accepted from either a 200 body or an error body.

The private and the public deployment run the same binary and differ only in base URL.
That is the whole reason RayMol targets this API instead of shelling out to a
`colabfold_search` install.

PAIRING IS DELIBERATELY UNREACHABLE. The backend also serves POST /ticket/pair, and
nothing here will call it: boltz-mlx reads taxonomy only from `>UniRef100_*` headers and
only when a taxonomy DB is passed, so a paired alignment is inert there at best, and
marking target-homolog rows as paired to compensate asserts co-evolution across the very
interface an interface score measures -- it fails by reading HIGH rather than by
crashing. Per-chain unpaired MSAs only; see #298.

Nothing in this module threads, caches, prints, or touches the session. The background
half is `searching.py`, and the session half is `pymol.msa`.
"""
import json
import os
import tarfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import Request, urlopen

from .errors import MSAInputError, MSAServerError

#: Patch point for tests, exactly as `predictors.weights._urlopen` is one. NOTHING below
#: may call urllib.request.urlopen directly: `testing/tests/msa/msa_search.py` patches
#: this name, and a test that reached a real server would publish a sequence to a third
#: party from CI. A separate seam from the weight cache's on purpose -- patching one must
#: not silently gag the other.
_urlopen = urlopen

#: Where a search goes when nobody has said otherwise. A THIRD-PARTY SERVICE: searching
#: here publishes the query sequence to someone else's infrastructure. See
#: `msa.warn_if_public`, which says so out loud the first time a session uses one.
PUBLIC_SERVER = 'https://api.colabfold.com'

#: Hosts known to be public. Anything else is assumed to be a deployment the user
#: controls -- there is no way to tell a private ColabFold server from an unknown public
#: one by inspection, and warning about `msa.internal.example` on every search would
#: train people to ignore the warning that matters.
PUBLIC_HOSTS = frozenset(['api.colabfold.com'])

#: Env override, for the same reason every other RayMol backend knob has one
#: (RAYMOL_WEIGHTS_DIR, RAYMOL_PREDICT_HOST): it is settable before Python boots, which
#: the `msa_server` setting is not.
SERVER_ENV = 'RAYMOL_MSA_SERVER'

#: Socket timeout for one request. Not a bound on the SEARCH -- that runs for minutes on
#: the server and is bounded by the poll loop in searching.py.
DEFAULT_TIMEOUT = 30.0

#: The result tarball is streamed in 1 MiB chunks: a deep alignment is tens of MB and
#: cancellation is observed at chunk boundaries.
CHUNK_BYTES = 1 << 20

#: Modes the MSA endpoint understands, from ColabFold's client: `use_filter` picks
#: filtered vs `-nofilter`, `use_env` picks whether the environmental databases are
#: searched as well. 'env' is ColabFold's own default and is what AlphaFold-style
#: pipelines use.
MODES = ('env', 'all', 'env-nofilter', 'nofilter')

#: Refused by name rather than passed through, so the refusal explains itself instead of
#: arriving as a tarball with a pair.a3m nothing here would read. See the module docstring.
PAIRING_MODES = ('pairgreedy', 'paircomplete', 'pairgreedy-env', 'paircomplete-env')

#: ColabFold numbers query sequences from 101, and the a3m that comes back carries that
#: number as the query's header. Kept identical so an alignment RayMol searched for is
#: indistinguishable from one produced by colabfold_batch.
QUERY_INDEX = 101

#: The uniref alignment leads the merged a3m, as it does in ColabFold's `run_mmseqs2`.
UNIREF_A3M = 'uniref.a3m'

#: Never merged in even if the server returns one: it is the paired alignment.
PAIRED_A3M = 'pair.a3m'

#: Set by `msa_server`. Empty means "not configured"; see resolve().
_SERVER = ''


# -- where to search -----------------------------------------------------------

def normalize(server):
    """A usable base URL, or raise. Trailing '/' removed so joins stay predictable."""
    text = str(server or '').strip().rstrip('/')
    if not text:
        raise MSAInputError('an MSA server needs a URL, e.g. %s' % PUBLIC_SERVER)
    parts = urlsplit(text)
    if parts.scheme not in ('http', 'https') or not parts.netloc:
        raise MSAInputError(
            'invalid MSA server %r: expected a URL like %s or http://msa.internal:8080'
            % (server, PUBLIC_SERVER))
    return text


def set_server(server):
    """Point subsequent searches at `server`. '' restores the unconfigured state."""
    global _SERVER
    _SERVER = normalize(server) if server else ''
    return _SERVER


def resolve(server=''):
    """(url, where it came from), in the documented resolution order.

    Explicit argument, then the `msa_server` setting, then RAYMOL_MSA_SERVER, then the
    public default. The origin is returned rather than inferred by the caller because
    `msa_server` with no argument has to say WHY it is about to publish a sequence.
    """
    if server:
        return normalize(server), 'argument'
    if _SERVER:
        return _SERVER, 'msa_server'
    from_env = os.environ.get(SERVER_ENV)
    if from_env:
        return normalize(from_env), SERVER_ENV
    return PUBLIC_SERVER, 'default'


def host_of(server):
    """Hostname of `server`, for messages. Never raises -- messages must not fail."""
    try:
        return urlsplit(str(server)).netloc or str(server)
    except Exception:
        return str(server)


def is_public(server):
    """True when `server` is a known public deployment -- see PUBLIC_HOSTS."""
    netloc = host_of(server)
    return netloc.split('@')[-1].split(':')[0].lower() in PUBLIC_HOSTS


def check_mode(mode):
    """Return `mode` if this module will send it, else raise."""
    text = str(mode or '').strip()
    if text in MODES:
        return text
    if text in PAIRING_MODES:
        raise MSAInputError(
            'mode %r asks the server for a PAIRED alignment, which RayMol will not use:'
            ' nothing downstream reads its pairing, and passing target-homolog rows off'
            ' as paired inflates interface scores instead of failing. Search each chain'
            ' separately with one of: %s' % (text, ', '.join(MODES)))
    raise MSAInputError('unknown mode %r; expected one of: %s'
                        % (mode, ', '.join(MODES)))


def user_agent():
    """How RayMol identifies itself.

    The public server asks clients to send a real one and throttles anonymous traffic
    harder; ColabFold's client warns when it is missing and says the warning will become
    an error. Version lookup is best-effort: an unavailable `_cmd` must not stop a search.
    """
    version = 'unknown'
    try:
        from pymol import cmd as _cmd_module
        version = str(_cmd_module.get_version()[0])
    except Exception:
        pass
    return 'RayMol/%s (https://github.com/javierbq/RayMol)' % version


# -- requests ------------------------------------------------------------------

def query_fasta(sequence):
    """The one-sequence FASTA the ticket carries. One chain only -- see the docstring."""
    text = ''.join(str(sequence).split()).upper()
    if not text:
        raise MSAInputError('nothing to search for: the query sequence is empty')
    return '>%d\n%s\n' % (QUERY_INDEX, text)


def _json_or_none(body):
    try:
        return json.loads(body.decode('utf-8', 'replace'))
    except Exception:
        return None


def _reason(payload):
    """The server's own explanation, if it gave one. Rate limits carry a `reason`."""
    if isinstance(payload, dict):
        for key in ('reason', 'error', 'message'):
            value = payload.get(key)
            if value:
                return str(value)
    return ''


def _rate_limited(server, payload):
    return MSAServerError(
        'the MSA server at %s is rate-limiting this client%s. It refused the search --'
        ' it did not run one -- so try again later, or point RayMol at a deployment you'
        ' control with: msa_server https://your.server'
        % (host_of(server), (': ' + _reason(payload)) if _reason(payload) else ''))


def _maintenance(server, payload):
    return MSAServerError(
        'the MSA server at %s is under maintenance%s; try again in a few minutes'
        % (host_of(server), (': ' + _reason(payload)) if _reason(payload) else ''))


def _json_request(url, server, data=None, timeout=DEFAULT_TIMEOUT):
    """One request that must answer with JSON. Every failure names the server.

    Naming it is not decoration: with a public default and a private override, "the
    search failed" is unactionable, while "msa.internal.example refused it" says at once
    whether the deployment is down or the sequence left the building.
    """
    request = Request(url, data=data, headers={'User-Agent': user_agent()})
    try:
        with _urlopen(request, timeout=timeout) as response:
            body = response.read()
    except HTTPError as exc:
        # HTTPError before URLError: it is a subclass, and a 429 carries the rate-limit
        # body that has to be read HERE or it is lost.
        payload = None
        try:
            payload = _json_or_none(exc.read())
        except Exception:
            pass
        status = str((payload or {}).get('status') or '').upper()
        if exc.code == 429 or status == 'RATELIMIT':
            raise _rate_limited(server, payload)
        if status == 'MAINTENANCE':
            raise _maintenance(server, payload)
        raise MSAServerError('the MSA server at %s refused the request: HTTP %s %s'
                             % (host_of(server), exc.code, exc.reason))
    except (URLError, OSError) as exc:
        raise MSAServerError(
            'cannot reach the MSA server at %s: %s. Check that it is running and'
            ' reachable from here, or set another with "msa_server".'
            % (host_of(server), getattr(exc, 'reason', exc)))
    payload = _json_or_none(body)
    if not isinstance(payload, dict):
        raise MSAServerError(
            'the MSA server at %s did not answer with JSON; is %s really a ColabFold'
            ' MSA server?' % (host_of(server), server))
    return payload


def submit(server, sequence, mode, timeout=DEFAULT_TIMEOUT):
    """Open a ticket for `sequence`. Returns the server's ticket dict.

    The backend keys a job on sha224(query + mode + databases), so re-submitting a query
    it has already run returns the SAME ticket -- frequently already COMPLETE. That is
    the server's cache, not ours, and it is why the poll loop must accept COMPLETE
    straight from the submit response.
    """
    data = urlencode({'q': query_fasta(sequence),
                      'mode': check_mode(mode)}).encode('utf-8')
    return _json_request(server + '/ticket/msa', server, data, timeout)


def poll(server, ticket_id, timeout=DEFAULT_TIMEOUT):
    """The current ticket dict for `ticket_id`."""
    return _json_request('%s/ticket/%s' % (server, quote(str(ticket_id), safe='')),
                         server, None, timeout)


def ticket_id(payload, server):
    """The id out of a ticket dict, or raise."""
    value = payload.get('id')
    if not value:
        raise MSAServerError('the MSA server at %s opened no ticket for this search'
                             % host_of(server))
    return str(value)


def check_status(payload, server):
    """The ticket's status, or raise for any state that is not progress.

    Every state the protocol defines is handled by name. An unrecognised one raises too:
    a server that has drifted must say so here, rather than be polled forever.
    """
    status = str(payload.get('status') or '').upper()
    if status in ('PENDING', 'RUNNING', 'COMPLETE'):
        return status
    if status == 'RATELIMIT':
        raise _rate_limited(server, payload)
    if status == 'MAINTENANCE':
        raise _maintenance(server, payload)
    if status == 'ERROR':
        raise MSAServerError(
            'the MSA server at %s could not build an alignment for this query%s. Check'
            ' that it is a valid protein sequence; if it is, the server may be having'
            ' trouble -- try again later.'
            % (host_of(server), (': ' + _reason(payload)) if _reason(payload) else ''))
    if status == 'UNKNOWN':
        raise MSAServerError(
            'the MSA server at %s does not know this ticket any more; it may have'
            ' expired. Search again.' % host_of(server))
    raise MSAServerError('the MSA server at %s answered with an unrecognised status %r'
                         % (host_of(server), payload.get('status')))


def download(server, id_, path, timeout=DEFAULT_TIMEOUT, should_cancel=None):
    """Stream the result tarball for `id_` to `path`.

    Streamed rather than buffered because a deep alignment is tens of megabytes, and
    checked for cancellation between chunks -- the same boundary the weight cache uses,
    and for the same reason: there is no way to interrupt a read already in flight.
    """
    url = '%s/result/download/%s' % (server, quote(str(id_), safe=''))
    request = Request(url, headers={'User-Agent': user_agent()})
    try:
        with _urlopen(request, timeout=timeout) as response:
            with open(path, 'wb') as handle:
                while True:
                    chunk = response.read(CHUNK_BYTES)
                    if not chunk:
                        break
                    handle.write(chunk)
                    if should_cancel is not None and should_cancel():
                        return path
    except HTTPError as exc:
        raise MSAServerError('the MSA server at %s would not hand over the result:'
                             ' HTTP %s %s' % (host_of(server), exc.code, exc.reason))
    except (URLError, OSError) as exc:
        raise MSAServerError('the result from %s could not be downloaded: %s'
                             % (host_of(server), getattr(exc, 'reason', exc)))
    return path


# -- the tarball ---------------------------------------------------------------

def a3m_from_tar(path, server=''):
    """(alignment text, list of the archive members it came from).

    The members are concatenated the way ColabFold's `run_mmseqs2` assembles them --
    uniref first, then the environmental databases -- because that concatenation IS the
    alignment every ColabFold-derived pipeline folds with, and an alignment that differs
    from the one colabfold_batch would have produced is a different input, not a tidier
    one. NUL bytes are stripped for the same reason ColabFold strips them: the server
    separates per-query blocks with them, and there is exactly one query here.

    Members are read through `extractfile` and never extracted to disk, so a crafted
    archive cannot write outside anywhere -- there is no path to traverse.
    """
    try:
        with tarfile.open(path, 'r:gz') as archive:
            members = [m for m in archive.getmembers()
                       if m.isfile() and os.path.basename(m.name).endswith('.a3m')]
            wanted = [m for m in members
                      if os.path.basename(m.name) != PAIRED_A3M]
            # uniref leads; everything else follows in a stable order, so the same
            # search twice gives byte-identical text.
            wanted.sort(key=lambda m: (os.path.basename(m.name) != UNIREF_A3M,
                                       os.path.basename(m.name)))
            if not wanted:
                raise MSAServerError(
                    'the result from %s contains no alignment (%s)'
                    % (host_of(server) or path,
                       ', '.join(sorted(m.name for m in archive.getmembers()))
                       or 'the archive is empty'))
            chunks, names = [], []
            for member in wanted:
                handle = archive.extractfile(member)
                if handle is None:
                    continue
                text = handle.read().decode('utf-8', 'replace').replace('\x00', '')
                if not text.strip():
                    continue
                if not text.endswith('\n'):
                    text += '\n'
                chunks.append(text)
                names.append(os.path.basename(member.name))
    except tarfile.TarError as exc:
        raise MSAServerError('the result from %s is not a readable tar.gz: %s'
                             % (host_of(server) or path, exc))
    except (IOError, OSError) as exc:
        raise MSAServerError('the result from %s could not be read: %s'
                             % (host_of(server) or path, exc))
    if not chunks:
        raise MSAServerError('the result from %s carries an empty alignment'
                             % (host_of(server) or path))
    return ''.join(chunks), names
