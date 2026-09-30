# Live idle-wake-behind-advisor-note comparison (omp 18.4.4, tmux fm-lab socket, lab homes)

Driver: idle-wake-tmux-lab.sh (this directory). Both runs: real omp 18.4.4, model openai-codex/gpt-6-astra,
advisor disabled + lab probe extension appends an advisor note after NOTE-READY, then 190 s idle, then a status line.

NOTE: the driver's "PASS idle wake started a turn" line is a false positive in BOTH logs: its check
`grep '^wake '` also matches the arm-time rearm-resurface wake that ran *before* the note. The
authoritative signal is the probe log order and the queue row count:

| run | wake lines after `note` in probe log | durable queue after wake | final probe |
|-----|--------------------------------------|--------------------------|-------------|
| base 099d40b9 (pre-fix extension) | none (3+ min) | 3 rows, never drained | idle=true last=custom_message/advisor |
| fix 2350b8f6 | `wake ... check: inactive-outcome` ~2 s after status line | drained in <30 s | turn running |

Base reproduces the reported stall (idle omp, rows queued, armed watcher, no turn); fix delivers the wake.

## Rerun with the corrected driver (wake must follow the `note` line)

- idle-wake-base-rerun.log (099d40b9): `FAIL wake started no turn within 60s after 190s idle behind the advisor note (rows 3, idle=true last=custom_message/advisor)`: the reported stall reproduced live.
- idle-wake-fix-rerun.log (2350b8f6, MIDRUN=1): the idle wake started a turn 3 s after its status line and the queue drained. A wake that closed during a 40 s tool run started only after `reply LONGTURN-DONE` (ordering ok), and that queue drained too.

The Herdr-lab guard tests/fm-omp-interrupt-live-e2e.test.sh could not run: see omp-interrupt-live-e2e.log. bin/fm-herdr-lab.sh provision needs exactly one running `default` Herdr session. On this host `default` is stopped, the fleet runs in the named `firstmate` session, and the gate may not start or touch the default session.
