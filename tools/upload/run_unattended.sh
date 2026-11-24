#!/usr/bin/env bash
# Unattended upload: runs the image uploader and commits/pushes its results file every 10 minutes.
# Resumable: re-run after any stop. Usage: tools/upload/run_unattended.sh <user-id> [jobs] [batch]
# batch = uploads per moderation gate (owner's rule since G-051: 100). Windows twin: run_unattended.ps1.
set -u
cd "$(dirname "$0")/../.."
python3 tools/upload/upload_images.py --user-id "$1" --jobs "${2:-8}" --batch "${3:-100}" &
pid=$!
commit() {
	git add assets/manifest/roblox-images.tsv tools/upload 2>/dev/null
	git commit -qm "M1-UPLOAD [Claude-Anvil] texture upload progress ($(grep -c '	ok	' assets/manifest/roblox-images.tsv) ok)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Hok2t2sSfeHWkAyoVz72sr" 2>/dev/null && git push -q 2>/dev/null
}
while kill -0 $pid 2>/dev/null; do
	for _ in $(seq 60); do kill -0 $pid 2>/dev/null || break; sleep 10; done
	commit
done
wait $pid
commit
echo "unattended run finished: $(grep -c '	ok	' assets/manifest/roblox-images.tsv) ok, $(grep -vc '	ok	' assets/manifest/roblox-images.tsv) other lines"
