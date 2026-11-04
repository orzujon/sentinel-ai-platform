"""Linux CI only: syntax-check actual rendered playbooks without connecting to guests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fresh_cluster as fresh

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    inventory = root / "inventory.json"
    inventory.write_text(json.dumps({"all": {"children": {"sentinel_sandbox": {"children": {
        "sentinel_control_plane": {"hosts": {"cp01": {}}},
        "sentinel_workers": {"hosts": {"w01": {}}}
    }}}}}))
    paths = [fresh.PLAYBOOKS / "05-fresh-identity.yml"]
    for stage, source in fresh.STAGES.items():
        path = root / (stage + ".yml")
        path.write_text(fresh.render_playbook(stage, (fresh.PLAYBOOKS / source).read_text()))
        paths.append(path)
    for path in paths:
        subprocess.run(["ansible-playbook", "--syntax-check", "-i", str(inventory), str(path)], check=True)
