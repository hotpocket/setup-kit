# Stable DHCP identity on workers

Set `net_dhcp_identifier=mac` in a worker's host conf to keep its DHCP identity
stable when cloud-init renames the NIC. Unset or empty leaves networking alone.
Only worker phase `03-headless` handles this key.

Defect class: every cloud VM whose NIC is renamed after first DHCP gets two leases.
systemd-networkd's default DUID+IAID identity changes when the interface name changes.

The phase reads `netplan get ethernets` and covers every ethernet config ID with
`dhcp4: true` or `dhcp6: true`. It uses config IDs, including IDs with `match` and
`set-name`, rather than assuming a kernel interface name. Static ethernets and
Wi-Fi are excluded.

If `netplan get` is unavailable or fails, system Python's existing PyYAML reads
the YAML hierarchy. Same-named files in `/run/netplan` shadow `/etc/netplan`, then
`/lib/netplan`; selected files merge by filename. This fallback extracts DHCP
flags without scraping YAML indentation. Missing PyYAML or unreadable YAML fails
without writing; no dependency is installed.

The owned file is `/etc/netplan/90-dhcp-mac.yaml`, mode `600`, owner `root:root`.
Content comparison uses exact bytes in deterministic flow style. A single `eth0`
produces the existing VM 105 repair verbatim, including its final newline:

```yaml
network: {version: 2, ethernets: {eth0: {dhcp-identifier: mac}}}
```

`check` reports drift without writing. `install` creates a temporary file in the
same directory, sets permissions and ownership, then renames it into place. It
runs `netplan generate` and restores the previous file and metadata on failure,
or removes the candidate if no file existed. It never runs `netplan apply` or
`try`; activation waits for the next reboot or DHCP renewal. `verify.sh` checks
coverage, content and metadata independently. `KIT_NETPLAN_ROOT` prefixes paths
for fake-root tests; normal runs use `/`.
