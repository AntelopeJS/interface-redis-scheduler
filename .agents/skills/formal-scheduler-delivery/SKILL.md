---
name: formal-scheduler-delivery
description: TLA+ model of task delivery in @antelopejs/interface-redis-scheduler (addTask, removeTask, enableListener, updateTimer, runTasks over the SchedulerUtil.Tasks sorted set and the SchedulerUtil channel), checked with TLC. Use when a change touches src/index.ts, or when a change to the timer, the lock, the take script or retries needs proof that it breaks no delivery rule.
---

# Formal check: scheduler task delivery

An app schedules a task with `addTask(handler, dueTime, info)`, which stores the member `handler:info` in the Redis sorted set `SchedulerUtil.Tasks` and publishes `update` on the `SchedulerUtil` channel. Every process that called `enableListener()` keeps one timer for the first queued task. When it fires, `runTasks()` takes every due member with one Lua script and hands each to its handler, one after the other. A handler that throws is queued again as `RETRY-n:handler:info` five seconds later, up to three times.

The model treats each Redis round trip as one step, and TLC checks every order of those steps across listeners and the app within the bounds below. The promise it checks is that every task the app adds and does not remove reaches its handler once, that concurrent batches claim each due task once and drop none, even when the app reschedules it mid-batch, and that one listener runs one handler at a time.

- `SchedulerState.tla` holds the constants, the variables and `Init`, and `SchedulerDelivery.tla`, which extends it, holds the actions and the rules. Each condition carries an `index.ts:NN` comment.
- `SchedulerDelivery.cfg` and `TwoListeners.cfg` are the full configurations, with one and two listeners. `Claim.cfg` has two listeners and an app that reschedules a task. Each has a `.ci.cfg` twin, the CI configuration.
- `SplitTake.cfg` and `split-take.mjs` hold the take from before #26, which must break the claim rules (see [The concurrent claim](#the-concurrent-claim)).
- `SchedulerDelivery.map.mjs`, `chart-bugs.cfg` and `chart-delivery.cfg` are for reading results with `/statechart`.

## Run it

From the repository root, with Node 24 and `pnpm install` done (the runner comes from `@antelopejs/tooling-configs/formal`):

```sh
node .agents/skills/formal-scheduler-delivery/check.mjs          # CI configuration
node .agents/skills/formal-scheduler-delivery/check.mjs --full   # full configuration
```

Java 11 or later comes from `$JAVA`, else `java` on PATH, else the `eclipse-temurin:21-jre` Docker image (set `TLC_DOCKER_PREFIX` to name the containers). The first run downloads TLC 1.7.4 into `~/.cache/antelopejs-formal` (or `$XDG_CACHE_HOME/antelopejs-formal`) and checks its SHA-256. Each run checks one listener first, then two, then the claim, then the split take.

| Configuration | One listener: tasks, retries | Two listeners: tasks, retries | Claim: tasks, retries, removeTask | States (one, two listeners, claim) | Wall time |
| --- | --- | --- | --- | --- | --- |
| CI (`<config>.ci.cfg`) | 2, 1 | 1, 1 | 1, 0, no | 22,367, 4,433, 26,761 | 17 s |
| Full (`<config>.cfg`) | 3, 1 | 2, 0 | 1, 0, yes | 1,848,104, 135,019, 98,627 | 37 s |

Both modes then check `SplitTake.cfg` (387,115 states). The times are one run each in Docker Java 21 on a shared machine with a load average between 12 and 14. The run that checks the rules that hold uses every core, and each finding runs on one worker.

- Exit 0 means every rule that held still holds, and each finding still breaks with its recorded counterexample length.
- Exit 1 means a rule changed. `BROKEN` names a rule that held and now breaks. `CHANGED` names a finding whose shortest counterexample changed length. `HOLDS` names a finding that no longer breaks. The script keeps TLC's output in a temporary folder and prints its path. The run stops at the first configuration that changed, so a change with one listener skips the two-listener run.
- Exit 2 means TLC or Java could not run, or the arguments were wrong.

The lines that name a changed rule match `^(?:BROKEN|CHANGED|HOLDS) +(\w+)`. A rule that still holds prints as lowercase `holds`. The split-take run prefixes its lines with `split take: `, so its required breaks never read as findings about `src/index.ts`; a changed rule there prints unprefixed, tagged `[split take]`.

## When to run it

Run `--full` when a change touches `src/index.ts` or this folder. A changed rule (exit 1) makes the Verdict FAIL. The recorded findings fail it only when the diff changes what `src/index.ts` does, which `antelopejs-verify formal` decides by comparing its JavaScript statements on the base and on HEAD (`verify-interface` verdict rule 5; the entry is `formal-scheduler-delivery` in `.agents/skills/verify-interface/verify.config.ts`). The CI configuration catches every scratch break in the last section, so it is the one CI runs (job `formal-scheduler-delivery`). TLC reads only this folder, so the job records a pass in the Actions cache under a key hashed from this folder, `package.json` and `pnpm-lock.yaml` (the install and the runner's version), `.nvmrc` and `ci.yml`, and a later push with the same key reuses that pass instead of running TLC again.

## The rules

A schedule is one write of a member: the pair of the member and the score that `addTask`, a reschedule or a retry gave it.

| Rule | Plain sentence | Harm when it breaks | One listener (CI, full) | Two listeners (CI, full) | Claim (CI, full) |
| --- | --- | --- | --- | --- | --- |
| `HandOffOnce` | Two batches, on one listener or on two, never take the same schedule. | A task runs twice, on one instance or on two. | holds | holds | holds |
| `NoDroppedTask` | Every stored schedule is still queued, was taken by a batch, deleted by `removeTask`, or replaced by a later `ZADD`. | A task leaves the queue without running. | holds | holds | holds |
| `AttemptsBounded` | A task's handler runs at most `MaxRetries + 1` times for each of its schedules a batch took. | A failing task retries without end, or one schedule runs twice. | holds | holds | holds |
| `RetriedBeforeGivingUp` | A task is given up only after its handler ran `MaxRetries + 1` times, as the retry logic of `runTasks` promises (index.ts:249). | A task that fails once is dropped without its retries. | holds | holds | holds |
| `NoOverlapOnInstance` | One listener runs one task handler at a time, as `locked` intends ("Flag to prevent concurrent task execution", index.ts:200-201). | Handlers that assume they run alone race on shared state, and a slow handler no longer holds back the next task. | finding F1 (12, 12) | holds, finding F1 (14) | finding F1 (15, 15) |
| `NoLostTask` | Once nothing more can happen, nothing is left queued, and every task the app added and did not remove reached its handler or used up its retries. | A scheduled task never runs. | holds | holds | holds |

`TypeOK` holds too. Without reschedules, `AttemptsBounded` and `RetriedBeforeGivingUp` together say a task given up ran exactly `MaxRetries + 1` times. `NoLostTask` is the liveness rule "every added task is eventually delivered" stated as an invariant: the shared runner checks invariants only, the model has no cycle, and under weak fairness every behaviour ends in a state where no step is enabled (`Quiescent`), so the rule asks for delivery in those states. A scratch run on the one-listener CI bounds confirmed both halves with `Spec /\ WF_vars(Busy)`: `<>Quiescent` holds (38,154 states at `acfb127`), and `<>[]Delivered` broke through the same race as F2, fixed since. The numbers in brackets are the states of TLC's shortest counterexample, which `check.mjs` records per configuration.

## The concurrent claim

`Claim.cfg` checks that two listeners claim each due task once and drop none while the app reschedules it. `split-take.mjs` checks that the take from before #26 (`TakeScript = FALSE`, `SplitTake.cfg`) still breaks `NoDroppedTask`, `HandOffOnce` and `AttemptsBounded`, so a model edit that stops catching a revert of #26 fails the check. [concurrent-claim.md](concurrent-claim.md) gives each counterexample and its replay on a real Redis.

## Findings on campaign/integration

Each finding was replayed against `dist/index.js` built at `db09714` and a real Redis 7. The replays were scratch scripts and are not committed. The step replay loads `dist/index.js` with an ioredis client whose `zrange`, `zscore`, `eval`, `zadd`, `zrem` and `publish` calls wait until the replay releases them to the real Redis, a fake `Date.now()` that moves 5 s per `Tick`, fake timers, and a subscriber whose `message` event the replay emits. It releases one command or fires one event per model action, in TLC's order.

- **F1, two handlers at once on one listener (`NoOverlapOnInstance`).** Only `updateTimer` reads `locked`, and only at entry (index.ts:212). The timer callback calls `runTasks` without reading it (line 229), and the due branch (lines 222-223) leaves an armed timer armed. In TLC's counterexample, task 1 is queued when a listener starts, and the start's `updateTimer` sends `ZRANGE`. The app adds task 2, and its `update` message starts a second `updateTimer`, which also passes `if (locked)`. Both `ZRANGE`s are sent while task 1 is first. The first finds it not yet due and arms a timer. The timer fires, and its batch sends the take script. Time passes, and the second `ZRANGE` reply finds task 1 past due and starts another batch. The first take hands task 1 to its handler, and the second hands task 2 to its handler while the first still runs. The step replay ended with `handlersRunning: 2, maxHandlersAtOnce: 2, handlerCalls: ["1","2"]`. A second replay with real timers and real pub/sub took the other path: a timer armed for task A at now+300 ms, then `addTask` of task B due in the past, whose `update` starts a batch for B (an 800 ms handler) while A's timer stays armed. Five runs out of five printed `{"most":2,"seen":["B starts with 1 running","A starts with 2 running"]}`.
- **F2, fixed by #38: a task stranded when removeTask raced the timer refresh (`NoLostTask`).** `updateTimer` read the first member with `ZRANGE ... 0 0` and its score in a second round trip, `ZSCORE`. When `removeTask` deleted that member in between, `ZSCORE` answered `null` and `updateTimer` returned without arming a timer or reading the next member, and `removeTask` publishes nothing. In TLC's counterexample (7 states on the one-listener CI bounds, 8 on the full ones, 25 with two listeners), tasks 1 and 2 are queued when a listener starts. The app calls `removeTask` for task 1, the start's `ZRANGE` names task 1, Redis deletes it, and `ZSCORE` answers no score. Task 2 falls due with no timer armed and nothing pending. The step replay logged `zrange -> ["task:1"]`, `zrem -> 1`, `zscore -> null`, then ended at tick 2 with `queued: ["task:2","10000"]`, no armed timer, no pending command and no handler call. `updateTimer` now reads the member and its score in one reply, `ZRANGE ... 0 0 WITHSCORES` (index.ts:217), so `ZrangeReply` sees one state of the queue, and `NoLostTask` holds in every configuration. The unit test `should still run the next task when the first is removed while the timer refreshes` replays the race against the code.

Issue drafts: `interface-redis-scheduler-concurrent-handlers` (F1) and `interface-redis-scheduler-remove-race-strands-queue` (F2).

## Read every result with /statechart

Read each TLC result with the pstack `/statechart` skill. Work on a copy of `SchedulerDelivery.tla`, `SchedulerState.tla`, the map and the chart configs in a scratch folder outside the repo, since it writes its output next to its input. Use `SchedulerDelivery.map.mjs` as the view: one region for the queue, one per listener and one for the app. `chart-bugs.cfg` (one listener, two tasks, no retry) is above the 500-state budget, so it draws only the bug paths. Since the fix for #38 that is one path, `NoOverlapOnInstance`, whose shortest counterexample has 12 states; `NoLostTask` holds there. `chart-delivery.cfg` (one task, one retry, no removal) draws the whole chart, 24 states and 52 arrows, and every rule holds there. The view hides `Settled`, the step that changes nothing once nothing else can happen. A new bug shows as a new numbered path, and a fix shows which bug paths it removes.

## Real bug or modeling error

Node runs other callbacks at every `await` that waits on I/O, so Redis replies, timer callbacks and `update` messages can interleave in any order the model allows. `GetClient()` returns a promise that is already resolved once interface-redis has its client, so awaiting it runs nothing else before the next command is sent. One listener sends all its commands on one connection, so Redis applies them in the order sent. A step order is a modeling error when the code cannot produce it, for example a reply handled before an earlier reply on the same connection, or one round trip split in two. Replay the counterexample with the step replay described above, one action per step. Assert only what an app observes: which handlers ran and when, and what `SchedulerUtil.Tasks` holds. If the replay does not reproduce the finding, treat the model as wrong until you show it is not.

## Changing the model

- For an intended code change, edit the action that maps to that code, keep the `index.ts:NN` comment on each condition and update its line, then run both configurations.
- Never weaken or drop a rule to make the check pass. A fixed finding leaves `CONFIGS` in `check.mjs`, for every configuration, once a replay confirms the fix. A new finding goes into `CONFIGS` with its counterexample length for each configuration, and into this file with its replay.
- When you change the bounds of a `.ci.cfg`, rerun the scratch changes below on it. The CI configuration must still catch each one.
- After you confirm that the model describes the code at a newer commit, move the sync commit forward. Do it only then.

## Coverage record

Every action models code in `src/index.ts`.

| Model action | Code |
| --- | --- |
| `Init` | queued members from before the listener started; `enableListener` subscribes and calls `updateTimer`, which sends `ZRANGE` (lines 88-101, 211-217) |
| `AddTaskCall`, `AddTaskZadd`, `Publish` | `addTask` checks the handler, sends `ZADD`, then `PUBLISH update` while `locked` is false (lines 152-166) |
| `RescheduleCall`, `RescheduleZadd` | `addTask` again for the same member, due later: `ZADD`, then `PUBLISH update` (lines 152-166) |
| `RemoveTaskCall`, `RemoveTaskZrem` | `removeTask` sends `ZREM` of `handler:info`, never a `RETRY-` member (lines 192-198, 65-67) |
| `NotifyUpdate` | the subscriber's `message` handler calls `updateTimer`, which returns while `locked` (lines 92-98, 212-214) |
| `ZrangeReply` | `updateTimer` reads the first member and its score in one `ZRANGE ... WITHSCORES`; an empty queue returns, a past score calls `runTasks`, a later one replaces the timer, capped at `MaxTimerDelayMs` (lines 217-233, 18) |
| `TimerFires` | the timer callback calls `runTasks` (lines 228-229) |
| `TakeReply` | `runTasks` sets `locked` and runs `TakeDueTasksScript` with `Date.now()` (lines 235-244, 251-254); with `TakeScript = FALSE`, the `ZRANGEBYSCORE` from before #26 (`a8d9d8c^`, line 250) |
| `ZremReply` | only with `TakeScript = FALSE`: the `ZREM` of the members read, from before #26 (`a8d9d8c^`, lines 251-252) |
| `HandlerReturns`, `HandlerThrows`, `RetryZaddReply` | the batch loop, the retry `ZADD` of `RETRY-n+1:` `RetryDelayMs` later below `MaxRetries`, then `locked = false` and `updateTimer` (lines 255-276, 16-17) |
| no action | `setHandler` and the `RegisteringProxy` callbacks (lines 24-60) register handlers before any task; `disableListener` (lines 120-122) quits the subscriber only |

The sync commit is the fix for #38 on AntelopeJS/interface-redis-scheduler `main`, where `src/index.ts` last changed. The findings were replayed at `db09714`.

## Bounds and what is left out

Task `t` is due at tick `t`, and a reschedule moves it to tick `t + 1`. The CI configuration runs one listener with 2 tasks and one retry, and two listeners with 1 task and one retry. The full one runs one listener with 3 tasks and one retry, and two listeners with 2 tasks added while they run and no retry. Each of those lets the app remove task 1 once and reschedules nothing. The claim configuration runs two listeners with 1 task, no retry, and one reschedule; the full one also lets the app remove it once. Two tasks took 516 s, too slow for every change. Where `PreQueued` is `TRUE` (all but the full two-listener configuration), `Init` starts with any subset of the tasks queued, as when a listener restarts. A pass covers these bounds only.

A configuration with reschedules has no retries (`ASSUME Reschedulable = {} \/ MaxRetries = 0`): a task that runs twice could write `RETRY-1` at the same score twice, which would read as one schedule taken twice.

The model leaves out:

- Redis errors and rejected commands: a take or retry `ZADD` that rejects (issues #27 and #29), and a dropped connection.
- crashes. A listener that dies after the take loses that batch, since the take already removed it: delivery is at most once, and the TSDoc promises retries only for a handler that throws. The scratch change `crash-after-take` below shows it.
- members whose handler is not registered in the listener (index.ts:258 skips them silently), and `taskInfo` values.
- `disableListener`, which leaves timers and batches running.
- two members with the same score; `First` picks one, and Redis orders them by member.
- clock skew between instances, and `Date.now()` moving within one step.

No rule depends on the `if (locked)` return of `updateTimer` (index.ts:212-214) alone, so the check does not catch its removal: both configurations still exit 0. Today F1 already lets a second batch start, and the removal keeps F1's shortest counterexample. With the `fix-lock-guards` fix below, the due branch reads `locked` too, and removing the entry check on top of that fix still leaves `NoOverlapOnInstance` holding.

## Confirm the check can fail

On a scratch copy of this folder (with `node_modules` reachable, for example a symlink beside it), apply one model edit at a time and run `check.mjs` with and without `--full`. Each edit mirrors the code change in the first column. These ran at `acfb127` or `db09714`, before the fix for #38 merged `ZscoreReply` into `ZrangeReply`, so their counts can be lower today.

| Scratch change in the code, and the model edit | CI configuration | Full configuration |
| --- | --- | --- |
| `drop-retry`: a handler that throws is never queued again (index.ts:265): `HandlerThrows` always gives up | `BROKEN RetriedBeforeGivingUp`, 7 states | `BROKEN RetriedBeforeGivingUp`, 7 states |
| `retry-once-more`: `retryCount <= MaxRetries` (line 265): `IF n <= MaxRetries`, and `Members` reaches `MaxRetries + 1` | `BROKEN AttemptsBounded`, 20 states | same |
| `drop-publish`: `addTask` publishes no `update` (lines 163-165): `AddTaskZadd` sends no publish | `HOLDS NoOverlapOnInstance` (1,001 states) | `HOLDS NoOverlapOnInstance` (11,478 states) |
| `never-unlock`: `runTasks` never clears `locked` (line 275), so its closing `updateTimer` returns at once: `NextMember` keeps `locked` and sends no `ZRANGE` | one listener `BROKEN NoLostTask`, 8 states (rerun after #38) | one listener `BROKEN NoLostTask`, 9 states (rerun after #38) |
| `crash-after-take`, no code change: a listener dies while a handler runs and restarts with `enableListener`: a new `Crash` action | not rerun after #38; before it, one listener unchanged and two listeners `BROKEN NoLostTask`, 11 states | not rerun after #38; before it, two listeners `CHANGED NoLostTask: 23 states (recorded 25)` |
| Fix candidate `fix-lock-guards`: the timer callback and the due branch of `updateTimer` skip `runTasks` while `locked` (lines 222-223, 229) | `HOLDS NoOverlapOnInstance` (18,866 states) | `HOLDS NoOverlapOnInstance` (989,683 states) |
| `revert-38`: `updateTimer` reads the score with a second `ZSCORE` again: a `ZscoreReply` step after `ZrangeReply`, as before the fix for #38 | `BROKEN NoLostTask`, 7 states | `BROKEN NoLostTask`, 8 states |

Every scratch run exited 1. With the edits dropped, both configurations exit 0. At `acfb127`, after the model gained reschedules and its schedule ledger, the CI runs of `drop-retry`, `retry-once-more` and `drop-publish` were repeated. The other cells date from `db09714`. The `revert-38` cells are the `NoLostTask` record `check.mjs` held at `acfb127`. Before #38 the recorded `NoLostTask` finding hid `never-unlock` on one listener; without it the one-listener run catches it first. The split take, once a scratch row, is now `SplitTake.cfg`.
