# ocr-tts — optional component (prompt user; gate on qualified GPU)

Custom OCR + TTS tooling from the `.configs` repo: kokoro TTS clipboard
server/client, nerd-dictation hotkeys, and screen-region OCR-to-clipboard.
These are personal tools, not baseline provisioning — **the setup flow
should PROMPT the user** rather than install unconditionally, and TTS
should be **gated on a qualified graphics card** (kokoro inference; CPU-only
boxes shouldn't get it by default).

Owner decision (2026-06-06, .configs session): python version installs are
setup-kit's job, not `.configs/setup.sh` — see that repo's
`ocr-and-tts-setup.sh` (commit c137304) + `setup.sh install` for the
current working reference until this component absorbs them.

## Gate

- Detect GPU: `lspci | grep -iE 'vga|3d'` + check for nvidia/amdgpu with
  usable VRAM (TODO: define "qualified" — kokoro is small, ~82M params;
  decide the actual floor, possibly allow CPU opt-in).
- If qualified (or user opts in anyway): prompt y/N per sub-tool
  (TTS server/client, dictation, OCR).

## What it installs (reference: ~/git/.configs)

1. **apt deps** — pyenv build chain + OCR tools:
   `make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev
   libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev
   libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev`
   plus `maim imagemagick xsel tesseract-ocr libreadline8`
   (tesseract/maim/imagemagick/xsel are what `bin/ocrscr` needs).
2. **pyenv** — `curl -fsSL https://pyenv.run | bash`, install python
   (was 3.12.11), virtualenv `kokoro-tts`.
3. **pip** — `kokoro soundfile python-vlc` into that venv.
4. **Script wiring** — `.configs/setup.sh install` does this part today:
   shebang-rewrites `tts-clipboard-{server,client}` into `~/bin`, installs
   autostart + .desktop files (sed `/home/brandon` → `$HOME`), symlinks
   `~/bin/nerd-dictation`, loads dconf hotkeys + notification settings.
5. **Verification** — `.configs/setup.sh check` (doctor mode) already
   verifies the wiring; reuse it rather than reimplementing.
