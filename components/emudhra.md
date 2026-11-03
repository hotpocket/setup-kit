# eMudhra admission

`component_emudhra=yes` opts in; default off. Phase 04 raises setup-kit's own
pyenv/pipx environment floors. Phase 07 and independent verification invoke
**only** `python3 components/emudhra-check --check`. Neither acceptance path
patches CAs, installs packages, removes Node versions or relinks runtimes.

`emudhra-check` promotes the read-only part of Beast's untracked `emudhra-fix`.
The source was inspected: no credentials are included. Its good-site
calibration and compromised-chain endpoints are retained; patch/relink code
is omitted. A reachable compromised chain fails; unreachable good sites or
unreadable probes are UNTESTED and fail admission.

Explicit floors:

| Consumer | Floor |
| --- | --- |
| Ubuntu ca-certificates | 20260816ubuntu0.26.04.1 |
| Node 22 / 24 / 26 | 22.23.4 / 24.22.1 / 26.12.1 |
| Other Node majors, including ≤20 | fail; replace with a supported major |
| certifi in every discovered venv, including pipx/shared/cache envs | 2026.10.19 |
| Installed pip in every discovered interpreter | 26.2.2 |
| Standalone Go 1.26 / 1.27, when found | 1.26.10 / 1.27.3 |

An absent pip is reported ABSENT, rather than counted as patched. An absent
certifi in a venv fails. Discovery traverses the user's HOME, `/usr/local`,
`/opt`, and interpreters on PATH, without a depth or cache exclusion. Symlink
cycles are bounded. Unreadable directories and broken environments fail
closed. The inventory prints versions and paths, never credential contents.

Python package floors come from `manifests/tool-versions.conf`. Distro
certifi resolving to `/etc/ssl/certs/ca-certificates.crt` uses the system CA
floor; a bundled `cacert.pem` still uses the certifi floor. Aliases within
one interpreter directory are checked once, preserving distinct venvs.
An interpreter without `ssl`/`_ssl` is reported ABSENT for TLS, while its
installed pip is still checked. Other probe errors remain UNTESTED. Node's
`CERT_REVOKED` is a certificate rejection, not a network failure.

This cannot attest every embedded Go runtime, container, remote/mounted
project store or application's private trust bundle. Inspect those separately
when restoring workloads. Re-run admission after restoring environments;
restarts following a later patch belong to the service's owner.

Tests: `bash tests/test-emudhra.sh`; `bash tests/test-python-trust-floor.sh`.
