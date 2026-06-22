# Third-party apt repos — enabled per-group, only when the group is selected

| Repo | Needed by (group) | Status |
|---|---|---|
| docker.list (download.docker.com) | dev-core (docker-ce…) | keep |
| vscode.sources (packages.microsoft.com/repos/code) | editors (code) | keep — package-managed; setup-kit must NOT add a vscode.list (Signed-By clash kills apt) |
| google-chrome.list | apps | keep — use the `.list`, NOT the broken `.sources` duplicate (missing Architectures → i386 warning) |
| brave-browser-release.list | apps | keep |
| cloud-sdk (packages.cloud.google.com) | dev-cloud (google-cloud-cli) | keep |
| winehq-noble.sources | wine | keep |
| steam-stable.list | games | keep |
| obsproject PPA | media (obs-studio) | keep |
| ppa:marin-m/songrec | media (songrec) | keep |
| ppa:danielrichter2007/grub-customizer | cli-system | keep (bare-metal relevance only) |
| ppa:alessandro-strada (google-drive-ocamlfuse) | apps | keep |
| nvidia-container-toolkit.list | conditional/nvidia | conditional |
| ddev.list | dev-core (ddev) | keep |
| charm.list | cli-system (glow via charm repo) | keep |
| minetestdevs PPA | games (minetest) | keep if games group on |
| ubuntu-esm-apps / esm-infra | cli-system | via `pro attach`, not raw lists |

Keyrings travel with their repo entries; never copy `*.distUpgrade`,
`*.save`, `*.dpkg-bak` variants.
