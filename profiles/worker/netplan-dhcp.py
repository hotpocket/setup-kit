#!/usr/bin/python3
"""Render the worker's owned drop-in from this machine's DHCP ethernet IDs."""
import copy
from pathlib import Path
import shutil
import subprocess
import sys

import yaml


def merge(base, incoming):
    for key, value in incoming.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        elif isinstance(value, list) and isinstance(base.get(key), list):
            base[key].extend(value)
        else:
            base[key] = copy.deepcopy(value)


def ethernets(root):
    # netplan get already implements the complete hierarchy and schema.
    if shutil.which("netplan"):
        result = subprocess.run(
            ["netplan", "get", "ethernets", "--root-dir", str(root)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            return yaml.safe_load(result.stdout) or {}
    # Older/minimal images may lack get. Parse YAML, never indentation: /run
    # shadows /etc shadows /lib by basename, then filenames merge in order.
    files = {}
    for directory in ("lib/netplan", "etc/netplan", "run/netplan"):
        for path in (root / directory).glob("*.yaml"):
            files[path.name] = path
    combined = {}
    for name in sorted(files):
        data = yaml.safe_load(files[name].read_text()) or {}
        merge(combined, data)
    return combined.get("network", {}).get("ethernets", {})


def main():
    devices = ethernets(Path(sys.argv[1]))
    if not isinstance(devices, dict):
        raise ValueError("invalid ethernet map")
    selected = {}
    for name, settings in sorted(devices.items()):
        if not isinstance(name, str) or not isinstance(settings, dict):
            raise ValueError("invalid ethernet definition")
        if settings.get("dhcp4") is True or settings.get("dhcp6") is True:
            selected[name] = {"dhcp-identifier": "mac"}
    if selected:
        # Keeping network outside the flow map matches the existing VM 105
        # repair exactly. PyYAML quotes unusual IDs without inventing NIC names.
        sys.stdout.write("network: " + yaml.safe_dump(
            {"version": 2, "ethernets": selected},
            default_flow_style=True, sort_keys=False, width=1000000,
        ))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError, yaml.YAMLError):
        # YAML errors can quote nearby Wi-Fi secrets. Report the remedy only.
        print("Cannot read DHCP ethernet IDs; check netplan get and netplan YAML.", file=sys.stderr)
        sys.exit(1)
