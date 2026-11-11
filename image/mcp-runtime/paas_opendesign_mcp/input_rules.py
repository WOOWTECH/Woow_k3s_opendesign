"""PaaS placement of the six HA 0.2.15 project/file argument rules.

Only the input rules are backported. The hash-pinned HA runtime under ha/ is
never edited; its secret-name guard remains the authority for read_file.
"""
import re
import json
from pathlib import Path

EXPECTED_HA_COMMIT = '200e8cbb1eac40aa53f4fcec1b05564b98f1c2eb'
PROJECT_ID_PATTERN = r'^\.*[A-Za-z0-9_-][A-Za-z0-9._-]*$'
FILE_PATH_PATTERN = r'^[A-Za-z0-9_㐀-鿿. /-]{1,256}$'
PROJECT_ID = re.compile(PROJECT_ID_PATTERN)
FILE_PATH = re.compile(FILE_PATH_PATTERN)


def require_pin():
    """Stop on a future HA re-pin until this compatibility overlay is reviewed."""
    manifest = Path(__file__).resolve().parents[1] / 'HA_SOURCE.json'
    if json.loads(manifest.read_text()).get('source_commit') != EXPECTED_HA_COMMIT:
        raise RuntimeError('HA source pin changed; review PaaS OpenDesign input overlay')


def safe_project_id(value):
    return isinstance(value, str) and len(value) <= 128 and PROJECT_ID.fullmatch(value) is not None


def file_path_problem(value, *, for_read):
    if not isinstance(value, str) or FILE_PATH.fullmatch(value) is None:
        return 'path characters not allowed'
    if any(part in ('', '.', '..') for part in value.split('/')):
        return 'relative non-traversing path required'
    if for_read:
        from ha_opendesign_mcp.od_rules import secret_like
        if secret_like(value):
            return 'secret-like file name refused'
    return None
