# Third-party apt repos — enabled per-group, only when the group is selected

| Repo | Needed by (group) | Status |
|---|---|---|
| docker.list (download.docker.com) | dev-core (docker-ce…) | keep |
| vscode.sources (packages.microsoft.com/repos/code) | editors (code) | keep |
| google-chrome.list | apps | keep — use the `.list`, NOT the broken `.sources` duplicate (missing Architectures → i386 warning) |
| brave-browser-release.list | apps | keep |
| cloud-sdk (packages.cloud.google.com) | dev-cloud (google-cloud-cli) | **NEW — add** |
| winehq-noble.sources | wine | keep |
| steam-stable.list | games | keep |
| obsproject PPA | media (obs-studio) | keep |
| ppa:marin-m/songrec | media (songrec) | keep |
| ppa:danielrichter2007/grub-customizer | cli-system | keep (bare-metal relevance only) |
| ppa:alessandro-strada (google-drive-ocamlfuse) | apps | keep |
| nvidia-container-toolkit.list | conditional/nvidia | conditional |
| brostrend.list (wifi dkms driver) | conditional hardware | conditional — only the machine with that adapter |
| ddev.list | dev-core (ddev) | keep |
| charm.list | cli-system (glow via charm repo) | keep |
| maxmind PPA | ? — nothing in manual list maps to it | **review: likely drop** |
| microsoft-prod.list (mssql, dotnet) | — | **drop** (mssql + dotnet-sdk dropped) |
| opentofu.list | — | **drop** (tofu dropped) |
| webmin-stable.list | — | **drop** (webmin dropped) |
| bruno.list | — | **drop** (bruno dropped) |
| cursor.sources | — | **drop** (cursor dropped) |
| minetestdevs PPA | games (minetest) | keep if games group on |
| ubuntu-esm-apps / esm-infra | cli-system | via `pro attach`, not raw lists |

Keyrings travel with their repo entries; never copy `*.distUpgrade`,
`*.save`, `*.dpkg-bak` variants.

Non-repo installs (manual .deb): hll3270cdwpdrv (Brother printer —
conditional/printer-brother).
