# Owned Python trust floors

Internal part of `component_emudhra`; it has no separate flag. Phase 04 invokes
it after creating language/tool environments. Unset/off means no calls.

Check reads pip/certifi metadata from interpreters under `.pyenv/versions`,
`.local/share/pipx` (including shared) and legacy `.local/pipx`. Install upgrades
only environments below pip 26.2.2 or certifi 2026.10.19. A second run makes no
package request. A pip-less owned environment needs pip bootstrapped before
this repair can converge; the component records that gap.

It never overrides PEP 668, upgrades system pip with sudo or claims a distro
pip below the floor is acceptable. The independent admission scanner still
rejects that installed system pip; resolve it through the distro's package
policy before admission. See `components/emudhra.md`.

Test: `bash tests/test-python-trust-floor.sh`.
