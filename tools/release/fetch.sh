#!/usr/bin/env bash
# Download the pinned Xonotic release (HANDOFF §DECISIONS D-001/D-002) into work/download/,
# verify against the official sha512 list, and unpack into work/release-<build>/.
# Usage: tools/release/fetch.sh [standard|high|source|all]   (default: all)
# Needs network access to dl.xonotic.org (see README "Cloud environment").
set -euo pipefail
cd "$(dirname "$0")/../.."
V=0.8.6; BASE=https://dl.xonotic.org
# Official sha512 of xonotic-0.8.6.sha512 itself is not published; the per-file sums below are
# copied from it (fetched 2026-11-20) and pinned here so a tampered mirror is detected.
declare -A SUM=(
  [xonotic-$V.zip]=cb39879e96f19abb2877588c2d50c5d3e64dd68153bec3dd1bebedf4d765e506afa419c28381d7005aed664cb1a042571c132b5b319e4308cab67745d996c2a6
  [xonotic-$V-high.zip]=d2fc8cc2c17220d7519067c2e20f438d3446999336ac3257a788b40bbc16faf801d349493929e6204b683fff2adecc7f0965b23e82484da780ce5a27d6264c90
  [xonotic-$V-source.zip]=88aa9cf35aa8e4b067dcc313037414fbc3a3769d60e88097ae8a3fbd2343369e2e4eff454b19d8a59b9c0bcbe183ec6eb289f35fa9f36564a300a3664c0e9498
)
want=${1:-all}
mkdir -p work/download
get() { # file unpackdir
	local f=$1 dir=$2
	if [ ! -f "work/download/$f" ]; then curl -sSfL -o "work/download/$f.part" "$BASE/$f" && mv "work/download/$f.part" "work/download/$f"; fi
	echo "${SUM[$f]}  work/download/$f" | sha512sum -c --quiet
	if [ -n "$dir" ] && [ ! -d "work/$dir" ]; then mkdir -p "work/$dir" && unzip -q "work/download/$f" -d "work/$dir"; fi
	echo "ok $f"
}
case $want in
	standard) get xonotic-$V.zip release-standard ;;
	high) get xonotic-$V-high.zip release-high ;;
	source) get xonotic-$V-source.zip source ;;
	all) get xonotic-$V.zip release-standard; get xonotic-$V-high.zip release-high; get xonotic-$V-source.zip source ;;
esac
