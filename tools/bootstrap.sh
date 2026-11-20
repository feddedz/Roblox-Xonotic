#!/usr/bin/env bash
# Installs the pinned toolchain into ./.tools/bin (gitignored) by direct GitHub release download.
# Same versions as rokit.toml. Each archive is sha256-verified. Safe to re-run.
# Usage: tools/bootstrap.sh && export PATH="$PWD/.tools/bin:$PATH"
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=.tools/bin; DL=.tools/dl; mkdir -p "$BIN" "$DL"
fetch() { # name url sha256
	local name=$1 url=$2 sum=$3 f="$DL/$1.zip"
	if [ -x "$BIN/$name" ]; then return; fi
	curl -sSfL -o "$f" "$url"
	echo "$sum  $f" | sha256sum -c --quiet
	unzip -oq "$f" -d "$BIN" && chmod +x "$BIN/$name"
}
fetch lune   https://github.com/lune-org/lune/releases/download/v0.11.1/lune-0.11.1-linux-x86_64.zip 39859282ce677fce19e6eb45c37596a90a25c324c95b4e7e02d428b6cae294a1
fetch stylua https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-linux-x86_64.zip a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895
fetch selene https://github.com/Kampfkarren/selene/releases/download/0.31.0/selene-0.31.0-linux.zip dac452422747999ec4919bbb8bb52992b66aae533b60022bf005669de8616671
fetch rojo   https://github.com/rojo-rbx/rojo/releases/download/v7.7.1/rojo-7.7.1-linux-x86_64.zip 00feb4fa0829a1dd72b49df2639da519a352bfe13cadcd83969e2ba2bb5693c4
python3 -m pip install -q -r tools/requirements.txt
"$BIN/lune" --version; "$BIN/stylua" --version; "$BIN/selene" --version; "$BIN/rojo" --version
