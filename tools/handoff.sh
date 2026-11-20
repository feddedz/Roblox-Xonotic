#!/usr/bin/env bash
# Print one HANDOFF.md section without reading the rest: tools/handoff.sh STATUS [RULES TASKS ...]
# Sections: STATUS RULES TASKS MAP DIFFS DECISIONS QUESTIONS GOTCHAS
set -euo pipefail
cd "$(dirname "$0")/.."
for s in "$@"; do
	awk -v b="<!-- §$s -->" -v e="<!-- /§$s -->" '$0==b{on=1;next} $0==e{on=0} on' HANDOFF.md
done
