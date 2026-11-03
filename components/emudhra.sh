#!/bin/bash
section "eMudhra admission ($MODE) — components/emudhra.md"
# Never repair/update/relink as part of acceptance. No installer is invoked.
# Even install mode runs ONLY this read-only checker, which fails closed.
if ! python3 "$KIT_DIR/components/emudhra-check" --check; then
  fail "eMudhra admission failed — patch/rebuild the listed trust consumers and rerun --check"
  miss "eMudhra: admission failed"
fi
