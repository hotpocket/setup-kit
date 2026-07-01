#!/usr/bin/env python3
"""Generate curated apt manifests from snapshot/apt/manual.txt.

Applies the curation decisions: drops, optional groups (off by default),
conditional groups (hardware/virt-detected), and dev-stack grouping.
Sizes/sections come from dpkg on the machine where the snapshot was taken —
re-run there after a capture refresh.

Output: manifests/apt/*.list (+ optional/, conditional/), one package per
line, '# comment' lines allowed, sorted by installed size desc.
Installers must strip comments:  grep -hv '^\\s*#' file | awk '{print $1}'
"""
import subprocess, pathlib, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAP = ROOT / "snapshot/apt/manual.txt"
OUT = ROOT / "manifests/apt"

# ---------------------------------------------------------------- decisions
DROPS = {  # pkg: reason
    "tldr": "transitional (->tldr-hs); both gone from 26.04 — use tealdeer",
    "tldr-hs": "Haskell tldr client; dropped from 26.04 archive — use tealdeer",
    "webmin": "root web panel; Proxmox UI / Cockpit cover it",
    "usermin": "webmin's per-user sibling — same family, same verdict",
    "mssql-server": "1.1G; install piecemeal if ever needed",
    "mssql-server-fts": "with mssql-server",
    "mssql-tools": "with mssql-server",
    "mssql-tools18": "with mssql-server",
    "unixodbc-dev": "only needed by mssql tooling",
    "rstudio": "install piecemeal if needed",
    "azuredatastudio": "install piecemeal if needed",
    "mysql-workbench-community": "install piecemeal if needed",
    "cursor": "code (stable) is the keeper",
    "code-insiders": "code (stable) is the keeper",
    "signal-desktop": "not needed",
    "bruno": "not needed",
    "dotnet-sdk-6.0": "EOL since 2024; piecemeal if needed",
    "openshot-qt": "not needed",
    "tofu": "unused",
    "jdk-21": "replaced by default-jdk (track current)",
    "openjdk-17-jdk": "replaced by default-jdk (track current)",
    "packages-microsoft-prod": "MS repo bootstrap — repos were dropped",
    "steam-launcher": "replaced by steam-installer (multiverse). Valve's"
                      " package manages its own apt source; the kit adding"
                      " one breaks apt entirely (Signed-By clash). Migration"
                      " leaves a stale user steam.desktop (Exec=/usr/games/steam,"
                      " nonexistent) that hides Steam in GNOME — healed by"
                      " 07-components.sh",
    "steam-libs-amd64": "dependency of the launcher — never list directly",
    "steam-libs-i386": "dependency of the launcher — never list directly",
    "virtualbox-7.2": "replaced by unversioned 'virtualbox' (conditional)",
    # gone/renamed on Ubuntu 26.04:
    "acpi-support": "obsolete on 26.04",
    "cheese": "removed — GNOME Snapshot ships with the desktop",
    "fuse-zip": "removed from 26.04 archives",
    "gnome-shell-extension-appindicator": "integrated into 26.04 desktop",
    "gnome-shell-extension-desktop-icons-ng": "integrated into 26.04 desktop",
    "gnome-shell-extension-ubuntu-dock": "integrated into 26.04 desktop",
    "gnome-startup-applications": "removed on 26.04",
    "kerneloops": "removed on 26.04",
    "mousetweaks": "removed on 26.04",
    "nautilus-extension-gnome-terminal": "removed (Ptyxis era)",
    "neofetch": "dead upstream — fastfetch is the successor (in extras)",
    "pulseeffects": "renamed easyeffects (added to media group)",
    "vino": "dead — gnome-remote-desktop ships with the desktop",
    "wireless-tools": "removed — iw/nmcli are the modern tools",
    "paprefs": "PulseAudio-era; its pulseaudio-module-gsettings dep"
               " CONFLICTS with pipewire-pulse/ubuntu-desktop on 26.04 —"
               " causes an install/remove flap loop",
    "grub-customizer": "PPA has no 26.04 builds; bare-metal niche (extras"
                       " when it returns)",
    # legacy vendor printer drivers — modern CUPS + driverless IPP covers
    # almost everything; apt-install one of these only for a specific old printer
    "printer-driver-pnm2ppa": "legacy vendor printer driver",
    "printer-driver-m2300w": "legacy vendor printer driver",
    "printer-driver-foo2zjs": "legacy vendor printer driver",
    "printer-driver-splix": "legacy vendor printer driver",
    "printer-driver-c2esp": "legacy vendor printer driver",
    "printer-driver-min12xxw": "legacy vendor printer driver",
    "printer-driver-pxljr": "legacy vendor printer driver",
    "printer-driver-brlaser": "legacy vendor printer driver",
    "printer-driver-ptouch": "legacy vendor printer driver",
    "printer-driver-sag-gdi": "legacy vendor printer driver",
    "bluez-cups": "Bluetooth printer backend — not needed without a BT printer",
}

# Apps that came from direct .deb downloads (no apt repo) — pulled out of
# the apt manifests into debs.list, installed by 02b-debs.sh.
# method: url (stable latest-URL) | github (latest release asset) | manual
# name: (method, arg[, group]) — optional 4th 'group' gates on group_<x>=yes
DIRECT_DEBS = {
    "zoom": ("url", "https://zoom.us/client/latest/zoom_amd64.deb"),
    "discord": ("url", "https://discord.com/api/download?platform=linux&format=deb"),
    "obsidian": ("github", "obsidianmd/obsidian-releases:amd64.deb"),
    "minikube": ("url", "https://storage.googleapis.com/minikube/releases/latest/minikube_latest_amd64.deb", "dev_k8s"),
    "master-pdf-editor-5": ("manual", "https://code-industry.net/free-pdf-editor/ — version-pinned URLs"),
    "ganttproject": ("manual", "https://www.ganttproject.biz/download — version-pinned URLs"),
}

OPTIONAL = {  # group: (header, [pkgs])
    "dev-db": ("Databases — OFF by default; flip on in host config",
               ["postgresql", "mariadb-server"]),
    "dev-php": ("PHP — OFF by default", ["php", "composer"]),
    "dev-rust": ("Rust — OFF by default. PREFER rustup over these apt pkgs"
                 " (apt rust is stale); listed for completeness",
                 ["rustc", "cargo"]),
    "dev-r": ("R — OFF by default (rstudio was dropped; r-base likely"
              " orphaned — confirm before ever enabling)", ["r-base"]),
    "printing": ("Printing — CUPS + GUI, OFF by default (dev VMs and headless"
                 " boxes don't need it; modern printers are driverless IPP"
                 " once cups is present)",
                 ["cups", "cups-filters", "cups-client", "cups-bsd",
                  "system-config-printer", "system-config-printer-common"]),
    "extras": ("Niche/occasional tools — OFF by default (lean rule:"
               " defaults are only what makes stuff run). Flip"
               " group_extras=yes or install piecemeal",
               ["octave-control", "octave-image", "octave-io",
                "octave-optim", "octave-signal", "octave-statistics",
                "calibre", "john", "john-data", "freeipmi-tools",
                "ipmitool", "fio", "gsmartcontrol", "qemu-system-x86",
                "genisoimage", "libdvd-pkg", "fastfetch"]),
}
# dev-go is optional too but has no apt packages (manual install) — see
# manifests/lang/README note emitted below.

CONDITIONAL = {
    "nvidia": ("Only when an NVIDIA GPU is present (lspci | grep -i nvidia)."
               " Driver pkg may be superseded — prefer 'ubuntu-drivers"
               " install' for the driver itself",
               ["nvidia-driver-580", "nvidia-cuda-toolkit",
                "nvidia-container-toolkit"]),
    "virtualbox": ("Only on bare-metal non-Proxmox targets; skip when"
                   " provisioning a proxmox-host or inside any VM"
                   " (systemd-detect-virt). Plain 'virtualbox' from"
                   " multiverse — NOT Oracle's versioned virtualbox-7.2"
                   " (needs their repo; fails on fresh boxes)",
                   ["virtualbox"]),
}

# additions not in the snapshot (marked '+new' in output)
ADDITIONS = {
    # lsof: pslsof/lports aliases need it; only auto-installed (a dep of
    # something), so it never lands in manual.txt — pin it explicitly.
    # wl-clipboard: wl-copy/wl-paste back the tts-clipboard + ocr scripts;
    # was OCR-component-only, promoted to default.
    # scdaemon: the gpg<->smartcard bridge for the YubiKey OpenPGP chain
    # (pass->gpg->scdaemon->YubiKey). Has NO reverse-Depends, so under
    # --no-install-recommends nothing pulls it in — a fresh box can't reach
    # the card without it. pcscd: scdaemon.conf uses pcsc-shared, so the card
    # is reached via pcscd (python3-ykman Depends it, but pin explicitly —
    # the whole secret chain dies silently if it's absent).
    # tealdeer: the maintained Rust tldr client; provides /usr/bin/tldr with
    # the standard `tldr <cmd>` syntax. The snapshot's `tldr` (transitional ->
    # tldr-hs) and tldr-hs itself are BOTH gone from 26.04 (resolute) — apt
    # there has no candidate — so we install tealdeer by name instead (dropped
    # below). NOTE: tealdeer ships no offline cache; `tldr <cmd>` errors with
    # "Page cache not found" until seeded (`tldr --update`) or auto_update is
    # set in ~/.config/tealdeer/config.toml.
    # nethogs (per-process net) + lm-sensors (temps): optional backends for the
    # Astra Monitor GNOME extension (manifests/gnome-extensions.list); useful
    # standalone too. amdgpu_top (its AMD-GPU backend) is a deb (debs.list).
    "cli-system": ["lsof", "wl-clipboard", "scdaemon", "pcscd", "tealdeer",
                   "nethogs", "lm-sensors"],
    "games": ["steam-installer"],
    "media": ["easyeffects"],          # pulseeffects' successor
    "dev-core": ["shellcheck", "git-lfs",
                 # rootless docker (rootful daemon disabled, user-level
                 # dockerd; see 07-components)
                 "docker-ce-rootless-extras", "uidmap"],
    "dev-java": ["default-jdk"],
    "dev-cloud": ["google-cloud-cli"],
    "dev-python": ["libssl-dev", "zlib1g-dev", "libbz2-dev",
                   "libreadline-dev", "libsqlite3-dev", "libncurses-dev",
                   "xz-utils", "tk-dev", "libxml2-dev", "libxmlsec1-dev",
                   "libffi-dev", "liblzma-dev"],
    "dev-flutter-deps": ["libgtk-3-dev"],
}

# explicit pkg -> group overrides (beat section mapping)
OVERRIDES = {}
for p in ["build-essential", "gcc", "g++", "clang", "cmake", "ninja-build",
          "pkg-config", "libtool", "autoconf", "automake", "gdb", "make",
          "git", "gh", "jq", "sqlite3", "docker-ce", "docker-ce-cli",
          "docker-buildx-plugin", "docker-compose-plugin"]:
    OVERRIDES[p] = "dev-core"
for p in ["maven"]:
    OVERRIDES[p] = "dev-java"
for p in ["awscli"]:
    OVERRIDES[p] = "dev-cloud"
for p in ["python3-pip", "pipx", "python3-venv"]:
    OVERRIDES[p] = "dev-python"
for p in ["android-sdk-platform-tools-common"]:
    OVERRIDES[p] = "dev-flutter-deps"
for p in ["code", "obsidian"]:
    OVERRIDES[p] = "editors"
for p in ["google-chrome-stable", "brave-browser", "zoom",
          "google-drive-ocamlfuse"]:
    OVERRIDES[p] = "apps"
for p in ["wine-stable", "winehq-stable", "winetricks"]:
    OVERRIDES[p] = "wine"
# tldr: handy man-page TL;DRs. apt classifies it 'oldlibs' -> would land in
# libs-review (never installed); pin it to the default-ON CLI set.
for p in ["glow", "snapd", "tldr"]:
    OVERRIDES[p] = "cli-system"
# gir deps for the system-monitor GNOME shell extension — the extension is
# not an apt package, so nothing pulls these in; 'introspection' section
# would bury them in libs-review (never installed)
for p in ["gir1.2-gtop-2.0", "gir1.2-nm-1.0", "gir1.2-clutter-1.0"]:
    OVERRIDES[p] = "desktop"
OVERRIDES["ddev"] = "dev-core"

# version-pinned kernel packages: never migrate — the target's OS install
# brings its own kernel
KERNEL_CRUFT = ("linux-hwe-", "linux-headers-", "linux-image-",
                "linux-modules-", "linux-objects-", "linux-signatures-",
                "linux-tools-", "linux-cloud-tools-")

SECTION_TO_GROUP = {
    # libraries pinned as 'manual' — NOT installed by default; real deps
    # return automatically with whatever needs them
    **{s: "libs-review" for s in
       ["libs", "libdevel", "oldlibs", "introspection", "perl", "ocaml",
        "python", "non-free/libs", "non-free/video", "contrib/utils"]},
    **{s: "cli-system" for s in
       ["metapackages", "base", "kernel", "admin", "shells", "default",
        "utils", "text", "misc", "interpreters", "vcs", "doc", "math",
        "otherosfs", "contrib/otherosfs", "contrib/misc", "gnu-r"]},
    **{s: "desktop" for s in ["gnome", "x11", "fonts", "translations"]},
    "games": "games",
    **{s: "media" for s in ["sound", "video", "graphics"]},
    **{s: "network" for s in ["net", "web", "mail", "httpd", "database"]},
    "editors": "editors",
    "devel": "dev-core",
    "java": "dev-java",
    "non-free/devel": "dev-core",
}

HEADERS = {
    "cli-system": "Base system + CLI tools (default ON)",
    "desktop": "Desktop environment, GNOME bits, fonts (default ON)",
    "media": "Audio/video/graphics apps + codecs (default ON)",
    "network": "Network tools and services (default ON)",
    "apps": "GUI applications (default ON)",
    "editors": "Editors (default ON)",
    "games": "Games incl. steam — default OFF (most targets are headless"
             " nodes/VMs without dGPU or monitor; flip group_games=yes for"
             " a gaming desktop)",
    "wine": "Wine for Windows apps, e.g. MTGA (default ON)",
    "dev-core": "Dev: C/C++ chain, git/gh/jq, docker, sqlite (default ON)",
    "dev-java": "Dev: Java — current JDK + maven (default ON)",
    "dev-python": "Dev: pyenv build deps + pip/pipx (default ON). pyenv"
                  " itself + interpreters: see manifests/lang/",
    "dev-cloud": "Dev: cloud CLIs — aws, gcloud (default ON; gcloud needs"
                 " its vendor apt repo, see repos.md)",
    "dev-flutter-deps": "Dev: flutter Linux-desktop build deps + adb udev"
                        " rules (default ON; flutter SDK itself: lang/)",
    "libs-review": "Libraries that were marked 'manual' in the source set."
                   " NOT installed by setup — apt pulls real deps in"
                   " automatically. Kept for reference/debugging only",
}


def main():
    meta = {}
    out = subprocess.run(
        ["dpkg-query", "-Wf", "${binary:Package}\t${Installed-Size}\t${Section}\n"],
        capture_output=True, text=True).stdout
    for line in out.splitlines():
        name, size, sec = (line.split("\t") + ["", ""])[:3]
        meta[name.split(":")[0]] = (int(size or 0), sec)

    manual = [l.strip() for l in SNAP.read_text().splitlines()
              if l.strip() and not l.startswith("#")]
    manual = [p.split(":")[0] for p in manual]

    placed = set(DROPS) | set(DIRECT_DEBS)
    for _, (_, pkgs) in {**OPTIONAL, **CONDITIONAL}.items():
        placed |= set(pkgs)

    groups = collections.defaultdict(list)
    for p in manual:
        if p in placed or p.startswith(KERNEL_CRUFT):
            continue
        size, sec = meta.get(p, (0, "UNKNOWN"))
        g = OVERRIDES.get(p) or SECTION_TO_GROUP.get(sec, "misc-review")
        groups[g].append((size, p, sec))

    def write(path, header, rows, extra=()):
        lines = [f"# {header}", "#"]
        for size, p, note in sorted(rows, reverse=True):
            lines.append(f"{p:<44}# {size/1024:8.1f} MB  {note}")
        for p in extra:
            lines.append(f"{p:<44}# {'':>8}     +new")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        return len(rows) + len(extra), sum(r[0] for r in rows)

    OUT.mkdir(parents=True, exist_ok=True)
    for stale in OUT.rglob("*.list"):  # full regen — no stale groups
        stale.unlink()
    report = []
    for g in sorted(set(groups) | set(ADDITIONS)):
        if g == "libs-review":
            continue
        n, kb = write(OUT / f"{g}.list", HEADERS.get(g, g),
                      groups.get(g, []), ADDITIONS.get(g, []))
        report.append((g, n, kb))
    write(OUT / "libs-review.list", HEADERS["libs-review"],
          groups.get("libs-review", []))
    for g, (hdr, pkgs) in OPTIONAL.items():
        write(OUT / "optional" / f"{g}.list", hdr,
              [(meta.get(p, (0, ""))[0], p, meta.get(p, (0, "?"))[1])
               for p in pkgs])
    for g, (hdr, pkgs) in CONDITIONAL.items():
        write(OUT / "conditional" / f"{g}.list", hdr,
              [(meta.get(p, (0, ""))[0], p, meta.get(p, (0, "?"))[1])
               for p in pkgs])
    drop_rows = [(meta.get(p, (0, ""))[0], p, reason)
                 for p, reason in DROPS.items()]
    write(OUT / "dropped.list", "Record of curation drops — NEVER installed;"
          " kept so refresh runs don't re-propose them", drop_rows)

    # direct-deb apps: name<TAB>method<TAB>arg[<TAB>group] (consumed by 02b-debs.sh)
    deb_lines = ["# Apps with no apt repo — installed from vendor .debs by",
                 "# profiles/workstation/02b-debs.sh. Fields: name method arg",
                 "# methods: url=stable latest link, github=owner/repo:asset-suffix,",
                 "#          optional 4th field = group gate (host-conf group_<name>=yes)",
                 "#          manual=doctor-warns only (version-pinned vendor URLs)"]
    for name, spec in DIRECT_DEBS.items():
        method, arg = spec[0], spec[1]
        grp = ("\t" + spec[2]) if len(spec) > 2 else ""
        deb_lines.append(f"{name}\t{method}\t{arg}{grp}")
    (MANIFESTS := OUT.parent).mkdir(exist_ok=True)
    (MANIFESTS / "debs.list").write_text("\n".join(deb_lines) + "\n")

    total = sum(kb for _, _, kb in report)
    print(f"{'group':<22}{'pkgs':>6}{'size':>10}")
    for g, n, kb in sorted(report, key=lambda r: -r[2]):
        print(f"{g:<22}{n:>6}{kb/1024/1024:>9.2f}G")
    libs = groups.get("libs-review", [])
    print(f"{'(libs-review, skipped)':<22}{len(libs):>6}"
          f"{sum(r[0] for r in libs)/1024/1024:>9.2f}G")
    print(f"{'TOTAL default-on':<22}{'':>6}{total/1024/1024:>9.2f}G")
    misc = groups.get("misc-review", [])
    if misc:
        print("\nmisc-review (unclassified):", ", ".join(p for _, p, _ in misc))


if __name__ == "__main__":
    main()
