# aws-cli v2 — component (workstation profile, gated by `group_dev_cloud`)

Amazon's AWS command line, **v2**, installed from Amazon's own bundle to
`/usr/local/bin/aws` — not Ubuntu's apt `awscli`, which is v1.

- Docs: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- Bundle: `https://awscli.amazonaws.com/awscli-exe-linux-<arch>.zip` (x86_64, aarch64)

## Why v2, and why not apt

- `~/.aws/config` `sso_session` blocks and `aws sso login` against IAM
  Identity Center are v2-only. `.configs/bin/sso` drives exactly that flow; a
  box with v1 has an `aws` that cannot log in.
- apt has no v2 package. The v1 `awscli` in the archive is unmaintained
  upstream and installs to `/usr/bin/aws`, where it silently shadows or
  fights a v2 in `/usr/local/bin` depending on PATH order. The component
  removes it when found.
- Discovered 2026-09-13: `verify.sh` failed "apt: awscli not-installed" on a
  machine with a working v2 — the manifest said apt, dpkg could not see the
  bundle, and the verifier believed the manifest.

## Install (what 07-components does)

1. `curl -fsSL` the arch-specific zip into a temp dir, `unzip`, then
   `sudo ./aws/install --update` (idempotent: `--update` upgrades in place).
   `unzip` comes from the `cli-system` apt group.
2. If apt's `awscli` is installed, `apt-get remove` it first.
3. Check mode reports the installed major version and says what would run.

## Verify

`verify.sh` requires `aws --version` to report `aws-cli/2.*` when
`group_dev_cloud=yes`; v1 or absent is a FAIL that names v2.

## Not covered

- Pinning a specific v2 release. `--update` tracks Amazon's latest; a pin
  would need the versioned zip name (`awscli-exe-linux-x86_64-2.x.y.zip`).
- Shell completion (`aws_completer`) wiring.
