"""PaaS child entry: pinned HA child startup with the six input guards."""
from pathlib import Path
import sys

# The pinned child_spec intentionally sets PYTHONPATH only to the vendored app
# and runtime. Add the package root exactly as the HA child entry does.
sys.path.append(str(Path(__file__).resolve().parents[1]))

from ha_opendesign_mcp import child as ha_child  # noqa: E402
from paas_opendesign_mcp.child_contract import prepare  # noqa: E402


if __name__ == '__main__':
    prepare(ha_child)
    ha_child.main()
