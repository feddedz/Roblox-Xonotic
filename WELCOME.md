# Welcome

You don't need to read this whole repository; you can skip around. The short version is that this project
is a one-to-one port of Xonotic to Roblox that keeps the gameplay, UI, models and lighting as close to the
original as possible, with only these planned changes: it runs on Roblox servers instead of Xonotic
servers, console and mobile players get their own controls and slight gameplay assists, and game passes
are added much later in development.

Keyboard-and-mouse gameplay stays exactly Xonotic. The console/mobile assists and the game passes are
approved but not built until they are defined exactly (HANDOFF.md §QUESTIONS Q-009, decision D-018).

Where to go next:
- [`README.md`](README.md): how to sync with Rojo, test in Studio and take comparison screenshots.
- [`HANDOFF.md`](HANDOFF.md): the project's live state (status, rules, tasks, decisions, questions).
- [`CLAUDE.md`](CLAUDE.md): the protocol AI sessions follow.
- [`docs/chat/`](docs/chat/README.md): the live chat between sessions (on `main`).

## Sessions: name, roster, chat (do this first)
1. **Pick a name** `Claude-<Word>` from the list below that is not in `docs/chat/roster.md` on `main`
   (`tools/chat.sh names` lists the free ones), then `tools/chat.sh register <Word> "<task(s)>"`.
   That adds your roster line (name, start time, task, status `active`, branch). Never reuse a name.
2. **Read the chat**: `tools/chat.sh read` (last 50 lines of yesterday + today).
3. **Post** your start and plan: `tools/chat.sh post "starting; plan: ..."`.
4. Use the name everywhere: chat, session log file name (`docs/log/<date>-Claude-<Word>.md`), §TASKS claims
   (`claimed by Claude-<Word> <date>`), commit messages (`T-014 [Claude-<Word>] ...`).
5. **Finish**: `tools/chat.sh status finished` (or `abandoned`, with a note in chat); change task with
   `tools/chat.sh status active "<new task>"`.

**When to post** (one or two lines, link files/commits, never paste): on start (with plan), when you claim a
task, find something others should know, need something from another session (`@Claude-<Name>`), get
blocked, change direction, finish — and at least at every major step. The owner posts as `Owner`.
**When to read**: on start, before claiming a task, before merging, and every few major steps.
**Chat is not the record**: real decisions, differences, rules and questions also go into HANDOFF.md.
How it works (append-only daily files, posted straight to `main`, retried, no conflicts): docs/chat/README.md.

Name words (first come, first served; add words at the end if the list runs out):
<!-- names -->
Anvil Badger Beacon Bramble Cobalt Comet Cricket Dynamo Ember Falcon Fjord Flint Gadget Glacier Harbor
Heron Indigo Jasper Juniper Kestrel Lantern Lynx Magnet Maple Meteor Nimbus Nova Onyx Orbit Otter Pebble
Pixel Quartz Quill Raven Ripple Rocket Saffron Sparrow Spruce Tango Thistle Topaz Tundra Umber Velvet
Walnut Willow Yarrow Zephyr Zigzag Zinnia
<!-- /names -->
