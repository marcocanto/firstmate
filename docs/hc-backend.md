# hc runtime backend

hc is an experimental session-provider backend for herdr-core, the terminal core under Herdr.app.
It provides task terminals while Treehouse continues to provide git worktrees, the same split tmux uses.
herdr-core is not Herdr 1: the `herdr` backend ([`herdr-backend.md`](herdr-backend.md)) talks to the `herdr` multiplexer, and the two share no socket, id space, or CLI.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
This page owns operator setup and supported limits; the adapter header in `bin/backends/hc.sh` explains implementation decisions.
[`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records what was exercised against a real core.

## Setup

Prerequisites:

- Herdr Core at version 0.1.15 or later, self-identifying as `hc x.y.z`, and a core speaking protocol generation 1.
  0.1.15 is the first version whose `hc run --name` (the task-derived terminal name) was verified; the adapter passes it on every create.
  Binary resolution uses an executable `FM_HC_BIN` override first, then `herdr-core` on `PATH`, then the `hc` alias.
  `hc` starts its own core on first use.
  [`bin/fm-install-hc.sh`](../bin/fm-install-hc.sh) owns installation usage and the checksum-verified release pin; updates remain operator-run.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select hc explicitly with local `config/backend` containing `hc`, `FM_BACKEND=hc` for one launch, or an explicit request to Firstmate.
An explicit setting always wins; see "Runtime auto-detection" below for when hc is also selected automatically.

The core a task lands on is the one `HC_SESSION` names when the task is spawned, or hc's `default` session when it is unset.
The Herdr app shows the terminals of the session it bound at launch, `default` unless the app was started with a different `HC_SESSION`.

## Runtime auto-detection

hc is auto-detected only on the Herdr app's terminal-level signal, never on bare `HC_TERMINAL_*` markers: hc stamps them into every process an hc terminal starts, and an app-created terminal's env is deliberately identical to any other hc terminal's - the app sends `TERM_PROGRAM=herdr` in its `terminal.run` call, but the core's `child_env` normalizes that to `ghostty` for every child, app-created or not.
What marks a terminal as the app's is its core-side record: the app stamps `herdr.space`/`herdr.tab` labels on every terminal it creates, and a non-empty `herdr.space` is the exact condition under which the app projects a terminal into its window.
[Backend selection order](configuration.md#backend-selection-order) owns precedence; this section owns the app-terminal signal.

Exactly one signal selects hc, after every other surface marker has had its say:

- `app-terminal`: this process's own `HC_TERMINAL_ID` terminal carries a non-empty `herdr.space` label in its core's record.
  The check is read-only and gated: a unix connect must first prove `HC_TERMINAL_SOCKET` live, because `hc` starts a core on contact with a missing socket and a bare `hc get` could create state; then one `hc get` reads the label through the resolved binary.
  Missing markers, a dead socket, a missing or unusable `hc`/`jq` toolchain, a `get` failure, or an empty label are all a miss, never a detection.

A live `herdr-app.sock` or an open window is deliberately not a signal: every process on the host can see it, so it cannot tell a Firstmate inside an app terminal from one on a bare shell while the window happens to be open elsewhere.
Live testing against the real app confirmed the ambiguity - marker-less processes selected hc solely because a window existed - so only the terminal-level claim above can auto-select hc.
A captain who wants a shell outside the app to spawn hc workers sets `config/backend`, `FM_BACKEND`, or `--backend` explicitly.

The signal binds the core a spawn would actually reach, the `HC_SESSION` (else `default`) session, and requires it to be running already, because the adapter's container ensure starts a missing core and detection must never start one.
`bin/fm-backend.sh` resolves that core's socket without calling `hc`: an `FM_HC_SOCKET` pin, else `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` when `XDG_RUNTIME_DIR` is set, else `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<session>/<session>.sock`, the layout measured on hc 0.1.14.
`app-terminal` additionally requires `HC_TERMINAL_SOCKET` to be that same socket, so a labeled terminal on some other core never steers a spawn.
The app shows the session it bound at launch, so a captain whose app runs a session other than `default` sets the same `HC_SESSION` for Firstmate or selects hc explicitly.

An explicit `--backend`, `FM_BACKEND`, or `config/backend` always wins over detection.
Inside the classic Herdr TUI, `HERDR_ENV=1` wins before the app signal is consulted, so the `herdr` backend keeps its behavior; inside tmux, `$TMUX` wins the same way, so a marker-less or contradictory process on either surface never sees the app check at all.
A contradictory marker set (for example another surface's marker alongside the app's) keeps the earlier surface's verdict rather than switching - ambiguous input means no automatic switch.
When a live hc terminal is present but no usable hc toolchain resolves (an executable `FM_HC_BIN`, or `herdr-core`/`hc` on `PATH` reporting `hc x.y.z` at or above the adapter's verified minimum, plus `jq` - the same version gate the spawn's container check applies), detection does not switch and a notice names the missing piece instead; a bare terminal marker set is still never a detection.
An auto-detected hc prints a stderr notice naming the winning signal and how to opt out; [Task shape and metadata](#task-shape-and-metadata) owns its task record.

Auto-detected hc spawns carry the same `herdr.space`/`herdr.tab` labels an explicit hc spawn does, so workers appear in the captain's window without the app ever being started by Firstmate.
The app is local GUI presentation only; detection reads the terminal's core-side label without requiring a live app window, so a surviving labeled terminal can still select hc after the GUI closes.
Nothing here changes the remote `herdr` path.

One limit applies to auto-detection specifically: away-mode supervisor discovery and hc refusal are owned by [Away-mode supervisor backend](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target).

## Task shape and metadata

Each task is one hc terminal running the user's login shell in the project directory, started with `--outlive-parent --no-notify` so it keeps running when Firstmate's own terminal ends and hc never types notes into Firstmate's composer.
When Firstmate itself runs in a live hc terminal of the task's session, the task terminal is created as that terminal's child, so Herdr.app groups the crew as sub-agents of the Firstmate that launched it; otherwise it starts with `--no-parent`.
Firstmate's terminal counts only when `HC_TERMINAL_ID` answers live in that session and its shell is an ancestor of the spawning process, so an inherited or stale id never adopts an unrelated terminal.
Each terminal also has a deterministic task-derived core name, with a readable prefix and a checksum of the full home-scoped task label.
Names fit hc's restricted alphabet and length; a name collision makes creation refuse rather than adopting or steering another terminal.
Names are presentation only: every operation still addresses the recorded terminal address and verifies its ownership labels.
Relaunch adopts that same terminal, so its name survives.
Herdr.app adopts `herdr.tab` terminals as unnamed tabs, so the core task name is available on the terminal/agent entry, not the tab; tabs stay numbered and Firstmate never drives the app window.
The terminal carries these labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `firstmate.task` | `fm-<id>` | Task identity checked before input or close. |
| `firstmate.home` | `<hometag>` from `bin/fm-backend-hometag-lib.sh` | Keeps two homes with the same task id apart. |
| `herdr.space` | `FM_HC_SPACE` when set, else the space of Firstmate's own hc terminal, else `fm-<hometag>` | Groups a home's tasks in one Herdr.app space, beside Firstmate when it runs in one. |
| `herdr.tab` | `<hometag>-fm-<id>` | One Herdr.app tab per task. |

```text
backend=hc
backend_detect=app-terminal
window=<session>:<address>
hc_session=<session>
hc_terminal=<address>
```

`backend_detect=` is `app-terminal` only when that signal automatically selected hc; an explicitly selected hc writes no `backend_detect=` line.

`<address>` is hc's terminal address such as `t7`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
`FM_HC_SOCKET` is the deliberate socket pin tests and labs use instead of an inherited `HC_SOCKET`.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` plus the `hello` generation handshake over `hc connect` |
| Create task | `hc run --bg --parent <firstmate-terminal>` or `--no-parent`, then `--outlive-parent --no-notify --name <task-name> --cwd <project> --label ...` |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Send a line and submit | `hc send` |
| Submit with confirmation | `hc send --wait`; see submit safety under Limits |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

`bin/fm-control.sh <id> exit` and `relaunch` are supported for ship and scout tasks in a surviving, positively classified local terminal.
They use the shared [agent control contract](agent-control.md), including its composer, prompt, harness, and transactional refusal rules.
The process-state read verifies task/home labels before trusting the foreground, and a shell is agent-free only after a complete process-group scan.
A failed, incomplete, or unattributed process read refuses rather than claiming the agent stopped.

## Second mates

`bin/fm-spawn.sh <id> [<home>] --secondmate --backend hc`, or the same launch under a `config/backend` of `hc`, runs a persistent second mate in one hc terminal started like any task terminal, with the user's login shell in the mate's home.
The record it publishes is the ordinary hc shape above plus `kind=secondmate` and `home=`.
The terminal's `firstmate.task` and `firstmate.home` labels are the launching home's, because that home's record owns the terminal and every later read, input, and close checks them against that home.
Its presentation labels are the mate's own: `herdr.space` is `fm-<mate hometag>`, the tag the mate home derives for itself (`bin/fm-backend-hometag-lib.sh` resolves `2ndmate-<id>` plus a short hash of that home), and `herdr.tab` is the launching home's scoped label for the mate.
A mate's own crew label their terminals with that same space, so Herdr.app shows the mate as its own agent with its crew as tabs beside it, apart from the primary's space.
`FM_HC_SPACE` is not consulted for a `--secondmate` launch, because it would move the mate out of the space its crew uses.
A second mate's terminal always starts with `--no-parent`, even when the launching Firstmate runs in an hc terminal, so the mate is never nested as a sub-agent of the primary; its own crew are then created as children of the mate's terminal.
Known limitation: when the mate's home is a linked git worktree, the app has been seen to show the mate's terminal in a space named after that folder and nested under the launching home's space rather than as its own top-level entry; the labels above are still applied, and this page records the behavior rather than working around it.
The mate's own spawns select hc through the inherited `config/backend` when the primary sets one, otherwise through the app-terminal signal its own labeled terminal carries.

Liveness and recovery follow the shared second-mate contract ([`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) "Recovery"; [`bin/fm-secondmate-liveness-lib.sh`](../bin/fm-secondmate-liveness-lib.sh) owns the mechanics).
The session-start sweep and the watcher's liveness tick classify the mate's terminal through the agent-state read above.
A terminal whose agent ended reads `dead` and is closed and removed before the respawn.
A terminal whose program finished reads `missing` while the core still lists it under `hc ls --all` with the mate's labels and tab, so the same idempotent close removes that husk first.
A terminal already gone is simply respawned, and an alive mate is never touched.
The respawn is `bin/fm-spawn.sh <id> --secondmate` on the mate's recorded backend, so a local hc second mate stays on hc whatever `config/backend` says.
[`bin/fm-secondmate-move.sh`](../bin/fm-secondmate-move.sh) `<id> --backend hc` moves an existing local mate from another local backend onto hc while keeping its home, records, and backlog, and recovery then keeps it on hc because the record names hc; its header owns the sequence and its refusals.
A remote second mate moves onto its own host's hc core instead, as [Move a remote second mate onto hc](remote-secondmates.md#move-a-remote-second-mate-onto-hc) describes.
A local hc second mate becomes a remote route on the same machine's core, keeping its home in place, as [Convert a local second mate to a remote route](remote-secondmates.md#convert-a-local-second-mate-to-a-remote-route) describes.
Lifecycle control of an hc second mate (`bin/fm-control.sh <id> interrupt`, `exit`, and `relaunch`) uses the same control plane, postconditions, and refusals as a ship or scout task on hc.
A `relaunch` keeps the mate's terminal and launches the replacement with the same Firstmate launch wiring a fresh spawn uses, including omp's `--config`.

A remote second mate can run on hc on its host: [Remote second mates](remote-secondmates.md#launch-or-recover) owns its placement, its readiness, and the rule that Firstmate never starts, stops, or restarts the host's core.
The host-side launch is this same second-mate launch, run by the remote job worker against the core the remote home's [`config/hc-session`](configuration.md#remote-hc-core-confighc-session) names.
Its terminal's `firstmate.home` label is the host code root's tag, because the host-local launch runs from that code root, and every host-side read checks the label against that same tag.

## Limits

- `hc send` always presses Enter, so hc cannot type without submitting.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- Submitting a message uses one bounded `hc send --wait`.
  A started turn or a still-working wait confirms it natively; otherwise the adapter falls back to the composer screen, with Enter retries only for a proven pending composer.
  hc refuses `hc send` (exit 9) to a terminal whose status is `blocked`, and `bin/fm-osc7501.sh` publishes a worker's open `needs-decision` or `blocked` status line as exactly that status.
  The adapter repeats a refused send with `--force` only when the blocked record is Firstmate's own (`app=firstmate-*`) and one screen read proves an empty composer with no recognized dialog.
  Any other blocked terminal, including one whose program reported the block itself, returns `unknown` without typing or retrying.
  `hc keys` is never refused, so Enter retries and interrupts need no force.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`, which works only for terminals on the local machine.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- A missing or finished terminal cannot be reclaimed by `relaunch`, nor treated as an idempotent successful `exit`.
  The record has no core or socket identity, so a not-found reply from a fresh core or another runtime directory cannot prove the original terminal gone.
- Plain `hc read` carries no styling.
  An idle-looking hint or typed text can therefore leave the composer `unknown`; `exit` and `relaunch` refuse until the shared classifier positively proves it empty.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; whether a real harness then reports native status under Firstmate's launch is not verified.
  A Firstmate process inside an hc terminal, such as a second mate spawning its own crew, reaches the core from that `HC_SESSION` through hc's default socket layout, because the adapter strips the inherited `HC_TERMINAL_SOCKET`.
  A core on any other socket, such as a `bin/fm-hc-lab.sh` session, needs `FM_HC_SOCKET` set in that process.
- Naming Herdr.app spaces or tabs needs the app window and is not done.
  The `herdr.space`/`herdr.tab` label contract above is the app's documented bridge (its window projects labeled terminals as spaces/tabs and keeps unlabeled ones hidden), verified against a real window: [`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records the live exercise.
- hc has no event stream this adapter consumes; supervision polls like tmux.

## Tests

`tests/fm-backend-hc.test.sh` pins the adapter against a fake `hc`.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real binary in an isolated lab; [`bin/fm-hc-lab.sh`](../bin/fm-hc-lab.sh) owns the isolation and metadata-tripwire contract, and [`tests/hc-test-safety.sh`](../tests/hc-test-safety.sh) owns guarded test teardown.
`tests/fm-backend-hc-appdetect-smoke.test.sh` runs a real `bin/fm-spawn.sh` spawn in the same kind of lab for the app-terminal and explicit cases, and checks that a live app window never selects hc for a marker-less process and starts nothing for a session with no running core.
`tests/fm-backend-hc-secondmate-smoke.test.sh` runs a real `--secondmate --backend hc` launch in the same kind of lab with a token-free stand-in agent, then drives the shared recovery library through a dead agent, a finished terminal, and an alive mate.
The fake-core cases for second mates live in `tests/fm-backend-hc.test.sh` (the launch and its labels) and `tests/fm-secondmate-liveness.test.sh` (the sweep's hc recovery and `bin/fm-secondmate-move.sh`).
The smokes skip when no resolved Core binary or `jq` is available; provisioning and teardown failures fail the test.
For CI coverage, see [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend); the workflow requires `jq` and rejects the `hc not found` skip.
[`bin/fm-hc-ci-cleanup.sh`](../bin/fm-hc-ci-cleanup.sh) owns job-end cleanup mechanics.
`tests/fm-control-hc-live-e2e.test.sh` is the prompt-spending opt-in guard (`FM_HC_CONTROL_LIVE=1`): real omp exit, idempotence, replacement, retained core name/local work, and refusal of pending input or unprovable absence.
