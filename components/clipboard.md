# clipboard — component (workstation, default on)

Copy and paste that behaves in GNOME Terminal on Ubuntu 26.04.

## The problem

- VTE (GNOME Terminal) pastes the **PRIMARY** selection on Shift+Ins and
  middle-click; 24.04 pasted CLIPBOARD on Shift+Ins. Ctrl+Shift+V pastes CLIPBOARD.
- 26.04's gschema default for `org.gnome.desktop.interface gtk-enable-primary-paste`
  is **false** (older releases shipped true), so middle-click paste is off.
- Plain `wl-copy` fills CLIPBOARD only, so text piped to it is invisible to
  Shift+Ins and middle-click.

## What it does

1. `gtk-enable-primary-paste true` (needs the desktop session's DBus; over ssh
   that is the user's bus while they are logged in at the desk).
2. `components/clipboard.bash` defines, for every interactive bash:
   - `pbcopy` / `pbpaste`: CLIPBOARD only (macOS semantics; deliberately not both).
   - `copy <file>`: the file onto CLIPBOARD and PRIMARY.
   Wayland uses wl-clipboard, X11 uses xclip; both come from the apt manifests
   (`cli-system`, `desktop`).
3. Wiring: `~/.local/share/setup-kit/clipboard.bash` links to the kit's file (so a
   moved kit is re-linked on the next run), and `~/.bashrc` gets one marked
   line that sources it. A `~/.bashrc` that is a **symlink** belongs to
   something else (the owner's `.configs`): the kit never writes through it,
   it only checks that it sources `clipboard.bash` and warns when it doesn't.
   The owner's `.configs/.bashrc` sources the sibling checkout
   (`$GIT_HOME/setup-kit/components/clipboard.bash`), so this file is the one
   copy of the functions.

## Host conf

`component_clipboard=yes` (default). `no` removes nothing that is already there.

## Doctor / verify

`check` reports primary paste and the `.bashrc` wiring and changes nothing.
`verify.sh` fails on primary paste off (independent of `dock=`) and on a
`~/.bashrc` that doesn't source `clipboard.bash`. `tests/test-clipboard.sh`.
