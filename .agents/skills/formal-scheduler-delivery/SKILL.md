---
name: formal-scheduler-delivery
description: TLA+ model of task delivery in @antelopejs/interface-redis-scheduler (addTask, removeTask, enableListener, updateTimer, runTasks over the SchedulerUtil.Tasks sorted set and the SchedulerUtil channel), checked with TLC. Use when a change touches src/index.ts, or when a change to the timer, the lock, the take script or retries needs proof that it breaks no delivery rule.
---

# Formal check: scheduler task delivery

An app schedules a task with `addTask(handler, dueTime, info)`, which stores the member `handler:info` in the Redis sorted set `SchedulerUtil.Tasks` and publishes `update` on the `SchedulerUtil` channel. Every process that called `enableListener()` keeps one timer for the first queued task. When it fires, `runTasks()` takes every due member with one Lua script and hands each to its handler, one after the other. A handler that throws is queued again as `RETRY-n:handler:info` five seconds later, up to three times.

The model treats each Redis round trip as one step, and TLC checks every order of those steps across listeners and the app within the bounds below. The promise it checks is that every task the app adds and does not remove reaches its handler once, and that one listener runs one handler at a time.

- `SchedulerDelivery.tla` holds the variables, the actions and the rules. Each condition carries an `index.ts:NN` comment.
- `SchedulerDelivery.cfg` and `TwoListeners.cfg` are the full configurations, with one and two listeners. Each has a `.ci.cfg` twin, the CI configuration.
- `SchedulerDelivery.map.mjs`, `chart-bugs.cfg` and `chart-delivery.cfg` are for reading results with `/statechart`.

## Run it

From the repository root, with Node 24 and `pnpm install` done (the runner comes from `@antelopejs/tooling-configs/formal`):

```sh
node .agents/skills/formal-scheduler-delivery/check.mjs          # CI configuration
node .agents/skills/formal-scheduler-delivery/check.mjs --full   # full configuration
```

Java 11 or later comes from `$JAVA`, else `java` on PATH, else the `eclipse-temurin:21-jre` Docker image (set `TLC_DOCKER_PREFIX` to name the containers). The first run downloads TLC 1.7.4 into `~/.cache/antelopejs-formal` (or `$XDG_CACHE_HOME/antelopejs-formal`) and checks its SHA-256. Each run checks one listener first, then two.

| Configuration | One listener: tasks, retries | Two listeners: tasks, retries | States (one, two listeners) | Wall time |
| --- | --- | --- | --- | --- |
| CI (`<config>.ci.cfg`) | 2, 1 | 1, 1 | 36,342, 10,902 | 5.9 s |
| Full (`<config>.cfg`) | 3, 1 | 2, 0 | 3,082,997, 664,781 | 28.6 s |

The times are one run each in Docker Java 21 on a shared 32-core machine with a load average near 18. The run that checks the rules that hold uses every core, and each finding runs on one worker.

- Exit 0 means every rule that held still holds, and each finding still breaks with its recorded counterexample length.
- Exit 1 means a rule changed. `BROKEN` names a rule that held and now breaks. `CHANGED` names a finding whose shortest counterexample changed length. `HOLDS` names a finding that no longer breaks. The script keeps TLC's output in a temporary folder and prints its path. The run stops at the first configuration that changed, so a change with one listener skips the two-listener run.
- Exit 2 means TLC or Java could not run, or the arguments were wrong.

The lines that name a changed rule match `^(?:BROKEN|CHANGED|HOLDS) +(\w+)`. A rule that still holds prints as lowercase `holds`.

## When to run it

Run `--full` when a change touches `src/index.ts` or this folder. A changed rule (exit 1) makes the Verdict FAIL. The recorded findings fail it only when the diff changes what `src/index.ts` does, which `antelopejs-verify formal` decides by comparing its JavaScript statements on the base and on HEAD (`verify-interface` verdict rule 5; the entry is `formal-scheduler-delivery` in `.agents/skills/verify-interface/verify.config.ts`). The CI configuration catches every scratch break in the last section, so it is the one CI runs on every push (job `formal-scheduler-delivery`).

## The rules

| Rule | Plain sentence | Harm when it breaks | One listener (CI, full) | Two listeners (CI, full) |
| --- | --- | --- | --- | --- |
| `HandOffOnce` | Two batches never take the same member. | A task runs twice, on one instance or on two. | holds | holds |
| `AttemptsBounded` | A task's handler runs at most `MaxRetries + 1` times. | A failing task retries without end. | holds | holds |
| `RetriedBeforeGivingUp` | A task is given up only after its handler ran `MaxRetries + 1` times, as the retry logic of `runTasks` promises (index.ts:250). | A task that fails once is dropped without its retries. | holds | holds |
| `NoOverlapOnInstance` | One listener runs one task handler at a time, as `locked` intends ("Flag to prevent concurrent task execution", index.ts:200-201). | Handlers that assume they run alone race on shared state, and a slow handler no longer holds back the next task. | finding F1 (14, 14) | holds, finding F1 (16) |
| `NoLostTask` | Once nothing more can happen, every task the app added and did not remove reached its handler or used up its retries. | A scheduled task never runs. | finding F2 (7, 8) | holds, finding F2 (25) |

`TypeOK` holds too. `NoLostTask` is the liveness rule "every added task is eventually delivered" stated as an invariant: the shared runner checks invariants only, the model has no cycle, and under weak fairness every behaviour ends in a state where no step is enabled (`Quiescent`), so the rule asks for delivery in those states. A scratch run on the one-listener CI bounds confirmed both halves with `Spec /\ WF_vars(Busy)`: `<>Quiescent` holds (36,342 states), and `<>[]Delivered` breaks through the same race as F2. The numbers in brackets are the states of TLC's shortest counterexample, which `check.mjs` records per configuration.

## Findings on campaign/integration

Each finding was replayed against `dist/index.js` built at the sync commit and a real Redis 7. The replays were scratch scripts and are not committed. The step replay loads `dist/index.js` with an ioredis client whose `zrange`, `zscore`, `eval`, `zadd`, `zrem` and `publish` calls wait until the replay releases them to the real Redis, a fake `Date.now()` that moves 5 s per `Tick`, fake timers, and a subscriber whose `message` event the replay emits. It releases one command or fires one event per model action, in TLC's order.

- **F1, two handlers at once on one listener (`NoOverlapOnInstance`).** Only `updateTimer` reads `locked`, and only at entry (index.ts:210). The timer callback calls `runTasks` without reading it (line 229), and the due branch (lines 222-223) leaves an armed timer armed. In TLC's counterexample, task 1 is queued when a listener starts, and the start's `updateTimer` sends `ZRANGE`. The app adds task 2, and its `update` message starts a second `updateTimer`, which also passes `if (locked)`. Both `ZRANGE`s name task 1. The first `ZSCORE` finds it not yet due and arms a timer. The timer fires, and its batch sends the take script. Time passes, and the second `ZSCORE` finds task 1 past due and starts another batch. The first take hands task 1 to its handler, and the second hands task 2 to its handler while the first still runs. The step replay ended with `handlersRunning: 2, maxHandlersAtOnce: 2, handlerCalls: ["1","2"]`. A second replay with real timers and real pub/sub took the other path: a timer armed for task A at now+300 ms, then `addTask` of task B due in the past, whose `update` starts a batch for B (an 800 ms handler) while A's timer stays armed. Five runs out of five printed `{"most":2,"seen":["B starts with 1 running","A starts with 2 running"]}`.
- **F2, a task strands when removeTask races the timer refresh (`NoLostTask`).** `updateTimer` reads the first member with `ZRANGE ... 0 0` (line 215) and its score in a second round trip, `ZSCORE` (line 217). When `removeTask` deletes that member in between, `ZSCORE` answers `null` and `updateTimer` returns (lines 218-220) without arming a timer or reading the next member, and `removeTask` publishes nothing. In TLC's counterexample, tasks 1 and 2 are queued when a listener starts. The app calls `removeTask` for task 1, the start's `ZRANGE` names task 1, Redis deletes it, and `ZSCORE` answers no score. Task 2 falls due with no timer armed and nothing pending. The step replay logged `zrange -> ["task:1"]`, `zrem -> 1`, `zscore -> null`, then ended at tick 2 with `queued: ["task:2","10000"]`, no armed timer, no pending command and no handler call. The window opens wherever no timer is already armed: the `updateTimer` of `enableListener` (a listener restarting with a queue) and the one that closes each batch after its timer fired.

Issue drafts: `interface-redis-scheduler-concurrent-handlers` (F1) and `interface-redis-scheduler-remove-race-strands-queue` (F2).

## Read every result with /statechart

Read each TLC result with the pstack `/statechart` skill. Work on a copy of `SchedulerDelivery.tla`, the map and the chart configs in a scratch folder outside the repo, since it writes its output next to its input. Use `SchedulerDelivery.map.mjs` as the view: one region for the queue, one per listener and one for the app. `chart-bugs.cfg` (one listener, two tasks, no retry) is above the 500-state budget, so it draws only the two bug paths, 14 states and 15 arrows: `NoLostTask` in 6 steps and `NoOverlapOnInstance` in 13. `chart-delivery.cfg` (one task, one retry, no removal) draws the whole chart, 24 states and 52 arrows, and every rule holds there. The view hides `Settled`, the step that changes nothing once nothing else can happen. A new bug shows as a new numbered path, and a fix shows which bug paths it removes.

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
| `Init` | queued members from before the listener started; `enableListener` subscribes and calls `updateTimer`, which sends `ZRANGE` (lines 88-101, 209-215) |
| `AddTaskCall`, `AddTaskZadd`, `Publish` | `addTask` checks the handler, sends `ZADD`, then `PUBLISH update` while `locked` is false (lines 152-166) |
| `RemoveTaskCall`, `RemoveTaskZrem` | `removeTask` sends `ZREM` of `handler:info`, never a `RETRY-` member (lines 192-198, 65-67) |
| `NotifyUpdate` | the subscriber's `message` handler calls `updateTimer`, which returns while `locked` (lines 92-98, 210-212) |
| `ZrangeReply`, `ZscoreReply` | `updateTimer` reads the first member, then its score; no score returns, a past score calls `runTasks`, a later one replaces the timer, capped at `MaxTimerDelayMs` (lines 215-233, 18) |
| `TimerFires` | the timer callback calls `runTasks` (lines 228-229) |
| `TakeReply` | `runTasks` sets `locked` and runs `TakeDueTasksScript` with `Date.now()` (lines 236-245, 252-255) |
| `HandlerReturns`, `HandlerThrows`, `RetryZaddReply` | the batch loop, the retry `ZADD` of `RETRY-n+1:` `RetryDelayMs` later below `MaxRetries`, then `locked = false` and `updateTimer` (lines 256-277, 16-17) |
| no action | `setHandler` and the `RegisteringProxy` callbacks (lines 24-60) register handlers before any task; `disableListener` (lines 120-122) quits the subscriber only |

The sync commit is `db09714` on AntelopeJS/interface-redis-scheduler `campaign/integration`. `src/index.ts` last changed in `1705d04`.

## Bounds and what is left out

Task `t` is due at tick `t`. The CI configuration runs one listener with 2 tasks and one retry, and two listeners with 1 task and one retry. The full one runs one listener with 3 tasks and one retry, and two listeners with 2 tasks added while they run and no retry. Every configuration lets the app remove task 1 once. Where `PreQueued` is `TRUE` (all but the full two-listener configuration), `Init` starts with any subset of the tasks queued, as when a listener restarts. A pass covers these bounds only.

The model leaves out:

- Redis errors and rejected commands: a take or retry `ZADD` that rejects (issues #27 and #29), and a dropped connection.
- crashes. A listener that dies after the take loses that batch, since the take already removed it: delivery is at most once, and the TSDoc promises retries only for a handler that throws. The scratch change `crash-after-take` below shows it.
- members whose handler is not registered in the listener (index.ts:259 skips them silently), and `taskInfo` values.
- `disableListener`, which leaves timers and batches running.
- two members with the same score; `First` picks one, and Redis orders them by member.
- clock skew between instances, and `Date.now()` moving within one step.

No rule depends on the `if (locked)` return of `updateTimer` (index.ts:210-212) alone, so the check does not catch its removal: both configurations still exit 0. Today F1 already lets a second batch start, and the removal keeps F1's shortest counterexample. With the `fix-lock-guards` fix below, the due branch reads `locked` too, and removing the entry check on top of that fix still leaves `NoOverlapOnInstance` holding.

## Confirm the check can fail

On a scratch copy of this folder (with `node_modules` reachable, for example a symlink beside it), apply one model edit at a time and run `check.mjs` with and without `--full`. Each edit mirrors the code change in the first column. These ran at the sync commit.

| Scratch change in the code, and the model edit | CI configuration | Full configuration |
| --- | --- | --- |
| `drop-retry`: a handler that throws is never queued again (index.ts:266): `HandlerThrows` always gives up | `BROKEN RetriedBeforeGivingUp: Initial -> ZrangeReply -> ZscoreReply -> Tick -> Tick -> TimerFires -> TakeReply -> HandlerThrows` | `BROKEN RetriedBeforeGivingUp`, 7 states |
| `retry-once-more`: `retryCount <= MaxRetries` (line 266): `IF n <= MaxRetries`, and `Members` reaches `MaxRetries + 1` | `BROKEN AttemptsBounded`, 20 states | same |
| `split-take`: the take reads with `ZRANGEBYSCORE`, then deletes what it read in a second round trip (lines 236-245): `TakeReply` only reads, a new `ZremReply` deletes | `BROKEN HandOffOnce`, 16 states; `CHANGED NoOverlapOnInstance: 15 states` | `BROKEN HandOffOnce`, 15 states; `CHANGED NoOverlapOnInstance: 15 states` |
| `drop-publish`: `addTask` publishes no `update` (lines 163-165): `AddTaskZadd` sends no publish | `HOLDS NoOverlapOnInstance` (947 states) | `HOLDS NoOverlapOnInstance` (11,478 states) |
| `never-unlock`: `runTasks` never clears `locked` (line 276), so its closing `updateTimer` returns at once: `NextMember` keeps `locked` and sends no `ZRANGE` | one listener unchanged; two listeners `BROKEN NoLostTask`, 12 states | two listeners `CHANGED NoLostTask: 23 states (recorded 25)` |
| `crash-after-take`, no code change: a listener dies while a handler runs and restarts with `enableListener`: a new `Crash` action | one listener unchanged; two listeners `BROKEN NoLostTask`, 11 states | two listeners `CHANGED NoLostTask: 23 states (recorded 25)` |
| Fix candidate `fix-lock-guards`: the timer callback and the due branch of `updateTimer` skip `runTasks` while `locked` (lines 222-223, 229) | `HOLDS NoOverlapOnInstance` (18,866 states) | `HOLDS NoOverlapOnInstance` (989,683 states) |
| Fix candidate `fix-refresh-again`: `updateTimer` reads the first member again when `ZSCORE` answers no score (lines 218-220) | `HOLDS NoLostTask` (39,743 states) | `HOLDS NoLostTask` (3,520,064 states) |

Every scratch run exited 1. With the edits dropped, both configurations exit 0.
