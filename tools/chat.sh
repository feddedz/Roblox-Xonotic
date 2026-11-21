#!/usr/bin/env bash
# Session chat + roster (CHAT-SETUP, ROSTER; docs/chat/README.md has the rules).
#
# The chat lives on the `main` branch in docs/chat/: one append-only file per UTC day and an append-only
# roster.md. This script never touches your working tree or branch: it reads origin/main directly and posts
# through a private detached worktree (inside .git), committing ONLY docs/chat/ files and pushing them
# straight to main. A rejected push (someone posted first) is retried on top of the new main, so parallel
# sessions never produce merge conflicts.
#
#   tools/chat.sh read [N]                 last N (default 50) lines of yesterday's + today's chat
#   tools/chat.sh names                    word list minus names already in the roster
#   tools/chat.sh register <Word> <task>   take the name Claude-<Word>, add an `active` roster line
#   tools/chat.sh post <message>           post as the registered name (or CHAT_NAME=Owner ...)
#   tools/chat.sh status <status> [task]   new roster line: active / finished / abandoned (+ current task)
#   tools/chat.sh roster                   current roster (latest line per name)
#   tools/chat.sh whoami                   the name this checkout posts as
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
GITDIR=$(cd "$(git rev-parse --git-common-dir)" && pwd)
WT="$GITDIR/chat-worktree"
NAMEFILE="$GITDIR/chat-name"
REMOTE=${CHAT_REMOTE:-origin}
BRANCH=${CHAT_BRANCH:-main}

# One chat command at a time per clone (they share the worktree and the remote-tracking ref).
if command -v flock >/dev/null; then
	exec 9>"$GITDIR/chat.lock"
	flock -w 300 9 || { echo "chat.sh: lock busy for 300 s" >&2; exit 1; }
fi

# Union merge for chat files, for anyone who merges or rebases branches that carry them.
mkdir -p "$GITDIR/info"
grep -qs 'docs/chat/\*\.md merge=union' "$GITDIR/info/attributes" ||
	echo 'docs/chat/*.md merge=union' >>"$GITDIR/info/attributes"

retry() { # retry <cmd...>: network commands, 4 retries with backoff
	local n=0 d=2
	until "$@"; do
		n=$((n + 1))
		[ $n -gt 4 ] && return 1
		sleep $d
		d=$((d * 2))
	done
}
fetch() { retry git -C "$ROOT" fetch -q "$REMOTE" "$BRANCH"; }
remote_file() { git -C "$ROOT" show "$REMOTE/$BRANCH:docs/chat/$1" 2>/dev/null || true; }
myname() {
	if [ -n "${CHAT_NAME:-}" ]; then
		echo "$CHAT_NAME"
	elif [ -s "$NAMEFILE" ]; then
		cat "$NAMEFILE"
	else
		echo "no name: run tools/chat.sh register <Word> <task> first" >&2
		exit 1
	fi
}
words() { # the word list is the fenced block after "Name words" in WELCOME.md
	awk '/^<!-- names -->/{on=1;next} /^<!-- \/names -->/{on=0} on' "$ROOT/WELCOME.md" | tr -s ' ,\n' '\n' | grep -E '^[A-Z][a-z]+$'
}
taken() { remote_file roster.md | { grep -oE "^Claude-[A-Za-z]+" || true; } | sort -u; }

# append <file> <line>: commit one line to docs/chat/<file> on main, retrying on a rejected push.
append() {
	local file=$1 line=$2 who
	who=$(myname)
	if [ ! -d "$WT" ]; then
		fetch
		git -C "$ROOT" worktree add -q --detach "$WT" "$REMOTE/$BRANCH"
	fi
	local try=0
	while :; do
		fetch
		git -C "$WT" reset -q --hard "$REMOTE/$BRANCH"
		mkdir -p "$WT/docs/chat"
		[ -f "$WT/docs/chat/$file" ] || printf '# %s\n\n' "${file%.md}" >"$WT/docs/chat/$file"
		printf '%s\n' "$line" >>"$WT/docs/chat/$file"
		git -C "$WT" add "docs/chat/$file"
		# Only chat files may ever be committed by this script.
		if git -C "$WT" diff --cached --name-only | grep -qv '^docs/chat/'; then
			echo "refusing: non-chat change staged" >&2
			exit 1
		fi
		git -C "$WT" -c user.name="$(git -C "$ROOT" config user.name || echo claude)" \
			-c user.email="$(git -C "$ROOT" config user.email || echo noreply@anthropic.com)" \
			commit -q -m "CHAT [$who] ${file%.md}" -- "docs/chat/$file"
		if git -C "$WT" push -q "$REMOTE" "HEAD:$BRANCH" 2>/dev/null; then
			echo "posted to $BRANCH:docs/chat/$file"
			return 0
		fi
		try=$((try + 1))
		if [ $try -ge 8 ]; then
			echo "push to $BRANCH failed 8 times; line not posted: $line" >&2
			exit 1
		fi
		sleep $((try * 2)) # someone posted first (or network): start again from the new main
	done
}

cmd=${1:-read}
shift || true
case $cmd in
read)
	n=${1:-50}
	fetch
	for d in "$(date -u -d yesterday +%F)" "$(date -u +%F)"; do
		out=$(remote_file "$d.md" | { grep "^\[" || true; } | tail -n "$n")
		[ -n "$out" ] && printf '== %s ==\n%s\n' "$d" "$out"
	done
	true
	;;
names)
	fetch
	comm -23 <(words | sed 's/^/Claude-/' | sort -u) <(taken)
	;;
register)
	[ $# -ge 2 ] || { echo "usage: register <Word> <task>" >&2; exit 2; }
	word=$1
	shift
	words | grep -qx "$word" || { echo "$word is not in the WELCOME.md word list" >&2; exit 1; }
	fetch
	if taken | grep -qx "Claude-$word"; then
		echo "Claude-$word is already in the roster; pick another (tools/chat.sh names)" >&2
		exit 1
	fi
	echo "Claude-$word" >"$NAMEFILE"
	now=$(date -u '+%Y-%m-%d %H:%M UTC')
	echo "$now" >"$NAMEFILE.start"
	append roster.md "Claude-$word | $now | $* | active | $(git -C "$ROOT" branch --show-current)"
	;;
post)
	[ $# -ge 1 ] || { echo "usage: post <message>" >&2; exit 2; }
	msg="$*"
	case $msg in *$'\n'*) echo "one message = one line" >&2; exit 2 ;; esac
	append "$(date -u +%F).md" "[$(date -u '+%Y-%m-%d %H:%M') UTC] $(myname): $msg"
	;;
status)
	[ $# -ge 1 ] || { echo "usage: status <active|finished|abandoned> [task]" >&2; exit 2; }
	st=$1
	shift
	case $st in active | finished | abandoned) ;; *) echo "status must be active, finished or abandoned" >&2; exit 2 ;; esac
	me=$(myname)
	fetch
	last=$(remote_file roster.md | { grep "^$me |" || true; } | tail -n 1)
	start=$(echo "$last" | cut -d'|' -f2 | xargs)
	task=${*:-$(echo "$last" | cut -d'|' -f3 | xargs)}
	append roster.md "$me | ${start:-?} | $task | $st | $(git -C "$ROOT" branch --show-current)"
	;;
roster)
	fetch
	remote_file roster.md | { grep "^Claude-" || true; } | tac | awk -F' [|] ' '!seen[$1]++' | tac
	;;
whoami) myname ;;
*)
	sed -n '2,17p' "$0"
	exit 2
	;;
esac
