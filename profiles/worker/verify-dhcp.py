#!/usr/bin/python3
"""Independent read-only DHCP check. Does not import the worker installer."""
from pathlib import Path
import subprocess
import sys

import yaml


def main():
    root = Path(sys.argv[1])
    try:
        response = subprocess.run(
            ["netplan", "get", "ethernets", "--root-dir", str(root)],
            capture_output=True, text=True, check=False,
        )
    except FileNotFoundError:
        response = None
    if response is not None and response.returncode == 0:
        devices = yaml.safe_load(response.stdout) or {}
    else:
        # Independent extraction of DHCP scalars. Later filenames override
        # earlier definitions; /run shadows /etc shadows /lib by basename.
        sources = {}
        for directory in ("lib", "etc", "run"):
            sources.update({p.name: p for p in (root / directory / "netplan").glob("*.yaml")})
        devices = {}
        for name in sorted(sources):
            data = yaml.safe_load(sources[name].read_text()) or {}
            for ident, settings in data.get("network", {}).get("ethernets", {}).items():
                devices.setdefault(ident, {}).update(settings)
    # Attribute an ineffective policy without printing unrelated YAML values.
    sources = {}
    for directory in ("lib", "etc", "run"):
        sources.update({p.name: p for p in (root / directory / "netplan").glob("*.yaml")})
    origins = {}
    for name in sorted(sources):
        data = yaml.safe_load(sources[name].read_text()) or {}
        for ident, settings in data.get("network", {}).get("ethernets", {}).items():
            if "dhcp-identifier" in settings:
                origins[ident] = str(sources[name])
    wanted = {}
    for ident in sorted(devices):
        properties = devices[ident]
        if properties.get("dhcp4") is True or properties.get("dhcp6") is True:
            if properties.get("dhcp-identifier") != "mac":
                source = origins.get(ident, "netplan merged settings")
                raise ValueError(f"DHCP identifier: {ident} is not mac; override in {source}; repair that setting and retry")
            wanted[ident] = {"dhcp-identifier": "mac"}
    if not wanted:
        return
    target = root / "etc/netplan/90-dhcp-mac.yaml"
    expected = "network: " + yaml.safe_dump(
        {"version": 2, "ethernets": wanted},
        default_flow_style=True, sort_keys=False, width=1000000,
    )
    if target.is_symlink() or not target.is_file():
        raise ValueError("missing regular file")
    metadata = subprocess.check_output(["stat", "-c", "%a:%u:%g", str(target)], text=True).strip()
    if metadata != "600:0:0" or target.read_bytes() != expected.encode():
        raise ValueError("file drift")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError, yaml.YAMLError) as exc:
        if isinstance(exc, ValueError) and str(exc).startswith("DHCP identifier:"):
            print(str(exc), file=sys.stderr)
        sys.exit(1)
