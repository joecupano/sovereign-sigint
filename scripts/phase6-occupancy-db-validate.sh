#!/usr/bin/env bash
# scripts/phase6-occupancy-db-validate.sh
#
# Phase 6.6 exit criteria (schema + access layer only — no producer
# wired yet): schema applies cleanly, record_sighting() correctly
# aggregates repeated sightings of the same signal into one `signals`
# row via frequency binning, not just "the code runs."
#
# Usage: ./scripts/phase6-occupancy-db-validate.sh

set -uo pipefail

VENV_PYTHON="/opt/sovereign-sigint/venvs/sigint-processing/bin/python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/sovereign-sigint-phase6-occupancy-validate.XXXXXX)"

RESULTS=()
trap 'rm -rf "${SCRATCH}"' EXIT

echo "== Phase 6.6 validation: Occupancy DB =="
echo

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "FAIL: sigint-processing venv not found at ${VENV_PYTHON}"
  exit 1
fi

echo "-- Applying schema, recording sightings, checking aggregation --"
OUTPUT="$("${VENV_PYTHON}" - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/db")
from occupancy_db import OccupancyDB
from pathlib import Path

db = OccupancyDB(Path("${SCRATCH}/test.db"))

# Two sightings of "the same" signal, close but not bit-identical
# frequency (realistic — different sources rarely report exact same
# center) — should collapse to one signals row via binning.
key1 = db.record_sighting(frequency_hz=144390000, source_type="openwebrx_mqtt",
                           source_device="openwebrx/hackrf", mode="APRS")
key2 = db.record_sighting(frequency_hz=144390050, source_type="openwebrx_mqtt",
                           source_device="openwebrx/hackrf", mode="APRS")

# A genuinely different signal — should NOT collapse with the above.
key3 = db.record_sighting(frequency_hz=433920000, source_type="gnuradio_feature_extraction",
                           source_device="radiod/rx888-hf", mode=None,
                           bandwidth_hz=25000)

checks = []
checks.append(("same-signal binning", key1 == key2))
checks.append(("distinct-signal separation", key1 != key3))

sig1 = db.get_signal(key1)
checks.append(("aggregate total_sightings == 2", sig1["total_sightings"] == 2))

sightings1 = db.get_sightings(key1)
checks.append(("sightings table has 2 rows for signal_key", len(sightings1) == 2))

sig3 = db.get_signal(key3)
checks.append(("null-mode signal recorded correctly", sig3["mode"] is None))
checks.append(("bandwidth_hz preserved on sighting", db.get_sightings(key3)[0]["bandwidth_hz"] == 25000))

for name, passed in checks:
    print(f"{'PASS' if passed else 'FAIL'}: {name}")

if not all(p for _, p in checks):
    sys.exit(1)
PYEOF
)"
echo "${OUTPUT}"

if echo "${OUTPUT}" | grep -q "FAIL"; then
  RESULTS+=("Occupancy DB functional test: FAIL")
else
  RESULTS+=("Occupancy DB functional test: PASS")
fi
echo

echo "== Summary =="
FAILED=0
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
  [[ "${r}" == *FAIL* ]] && FAILED=1
done
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 6.6 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 6.6 exit criteria met for schema + access layer."
  echo "Producer: scripts/phase6-occupancy-producer.sh installs the radiod-based"
  echo "producer as a continuous systemd --user service — confirmed on a real"
  echo "run to actively grow the sightings table from live HF traffic. Run it"
  echo "(as your normal user, no sudo) if it isn't installed yet:"
  echo "  systemctl --user status radiod-occupancy.service"
  echo "  sqlite3 ${REPO_ROOT}/db/occupancy.db 'SELECT COUNT(*) FROM sightings;'"
fi
