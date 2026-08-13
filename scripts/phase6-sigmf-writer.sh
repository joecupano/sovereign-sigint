#!/usr/bin/env bash
# scripts/phase6-sigmf-writer.sh
#
# Phase 6.5 — SigMF writer. See docs/build-order.md Phase 6. Ensures
# the sigint-processing venv is current (sigmf==1.11.1 already pinned
# in decode/requirements.txt) and that /data/signals/generated exists.
#
# This is a thin setup script — the actual work is
# decode/sigmf_writer.py, usable as a library or CLI. There's no
# always-on service for this phase (unlike Phase 5's ingest timer):
# SigMF generation is invoked per-capture, not on a schedule.
#
# Usage: ./scripts/phase6-sigmf-writer.sh

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — matches the venv-setup pattern" >&2
  echo "used elsewhere (Phase 5, Phase 6.3). Re-run without sudo." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== Phase 6.5: SigMF writer =="

echo "-- Updating sigint-processing venv --"
"${REPO_ROOT}/scripts/setup-venvs.sh" sigint-processing

if [[ ! -d /data/signals/generated ]]; then
  echo "ERROR: /data/signals/generated does not exist. Run scripts/setup-data-dirs.sh first." >&2
  exit 1
fi

cat <<'EOF'

== Phase 6.5 setup complete ==

Usage (CLI):
  /opt/sovereign-sigint/venvs/sigint-processing/bin/python3 \
    decode/sigmf_writer.py \
    --input <raw_iq_file> --output-name <name> \
    --sample-rate <Hz> --center-freq <Hz> --input-format ci16_le

Usage (library): from sigmf_writer import write_sigmf

Next: run scripts/phase6-sigmf-writer-validate.sh to confirm a real
synthetic round-trip (write, then read back and verify) works before
trusting this against a real capture.
EOF
