"""RCSB PDB search client for PyMOL AI chat.

Provides a simple interface to search the Protein Data Bank using the
RCSB Search API v2 and retrieve entry metadata. Uses only stdlib
(urllib) to avoid external dependencies.
"""

import json
import urllib.request
import urllib.error

_SEARCH_URL = "https://search.rcsb.org/rcsbsearch/v2/query"
_ENTRY_URL = "https://data.rcsb.org/rest/v1/core/entry/{pdb_id}"

# Timeout for individual HTTP requests (seconds)
_REQUEST_TIMEOUT = 10


def search_pdb(query, max_results=5):
    """Search the RCSB PDB for structures matching a text query.

    Parameters
    ----------
    query : str
        Free-text search query (e.g. 'human hemoglobin', 'CRISPR Cas9').
    max_results : int, optional
        Maximum number of results to return (default 5, clamped to 1-25).

    Returns
    -------
    list of dict
        Each dict contains:
        - pdb_id (str): 4-character PDB identifier
        - title (str): Structure title
        - organism (str or None): Source organism scientific name
        - resolution (float or None): Resolution in angstroms
    """
    max_results = max(1, min(25, int(max_results)))

    # Step 1: Full-text search for PDB IDs
    pdb_ids = _search_ids(query, max_results)

    if not pdb_ids:
        return []

    # Step 2: Fetch metadata for each ID
    results = []
    for pdb_id in pdb_ids:
        entry = _fetch_entry_metadata(pdb_id)
        if entry is not None:
            results.append(entry)

    return results


def _search_ids(query, max_results):
    """POST a full-text search to RCSB and return a list of PDB IDs.

    Returns
    -------
    list of str
        PDB IDs matching the query, up to max_results.
    """
    payload = {
        "query": {
            "type": "terminal",
            "service": "full_text",
            "parameters": {
                "value": query
            }
        },
        "return_type": "entry",
        "request_options": {
            "paginate": {
                "start": 0,
                "rows": max_results
            }
        }
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        _SEARCH_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # 204 No Content or other non-200 = no results
        return []
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return []

    result_set = body.get("result_set", [])
    return [entry["identifier"] for entry in result_set if "identifier" in entry]


def _fetch_entry_metadata(pdb_id):
    """GET metadata for a single PDB entry.

    Returns
    -------
    dict or None
        Dict with pdb_id, title, organism, resolution; or None on failure.
    """
    url = _ENTRY_URL.format(pdb_id=pdb_id)
    req = urllib.request.Request(url, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, OSError,
            json.JSONDecodeError):
        # Return a minimal entry if metadata fetch fails
        return {"pdb_id": pdb_id, "title": None, "organism": None, "resolution": None}

    # Extract title
    title = None
    struct = body.get("struct", {})
    if isinstance(struct, dict):
        title = struct.get("title")

    # Extract organism
    organism = None
    entry_info = body.get("rcsb_entry_info", {})
    if isinstance(entry_info, dict):
        # Try the list form first (can be a list of names)
        org = entry_info.get("organism_scientific_name")
        if isinstance(org, list) and org:
            organism = org[0]
        elif isinstance(org, str):
            organism = org

    # If organism not in rcsb_entry_info, try polymer_entities
    if organism is None:
        try:
            entities = body.get("polymer_entities", [])
            if entities and isinstance(entities, list):
                src = entities[0].get("rcsb_entity_source_organism", [])
                if src and isinstance(src, list):
                    organism = src[0].get("ncbi_scientific_name")
        except (KeyError, IndexError, TypeError):
            pass

    # Extract resolution
    resolution = None
    if isinstance(entry_info, dict):
        res = entry_info.get("resolution_combined")
        if isinstance(res, list) and res:
            try:
                resolution = float(res[0])
            except (ValueError, TypeError):
                pass
        elif isinstance(res, (int, float)):
            resolution = float(res)

    return {
        "pdb_id": pdb_id,
        "title": title,
        "organism": organism,
        "resolution": resolution,
    }
