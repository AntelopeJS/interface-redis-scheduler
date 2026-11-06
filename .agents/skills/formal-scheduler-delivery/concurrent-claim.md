# The concurrent claim

Why the model keeps the take from before #26, and what `split-take.mjs` requires of it. Read it from [SKILL.md](SKILL.md).

Before #26, `runTasks` read the due members with `ZRANGEBYSCORE`, then deleted them with `ZREM` in a second round trip (`a8d9d8c^`, index.ts:250-252). #26 made it one Lua script, `TakeDueTasksScript`. The constant `TakeScript` picks the take: `TRUE` models the code, `FALSE` the take before #26. `split-take.mjs` checks the CI claim bounds with `TakeScript = FALSE` (`SplitTake.cfg`) and exits 1 unless each of these still breaks with its recorded length:

- `NoDroppedTask`, 9 states, the bug #26 fixed: the `ZRANGEBYSCORE` reads task 1, the app's reschedule moves it later, and the `ZREM` deletes it with its new score.
- `HandOffOnce` and `AttemptsBounded`, 12 states: both listeners read task 1 before either `ZREM`, and both run its handler.
- `NoOverlapOnInstance`, 16 states: F1.

So a model edit that stops catching a revert of #26 fails the check. A code change back to a two-step take sets `TakeScript = FALSE` in the code configurations.

## Replay

A scratch replay (not committed) ran both paths on a real Redis 7, against `dist/index.js` built at the sync commit and against the same build with the take reverted by hand to the code before #26. Each scheduler instance got a client whose `eval` and `zrangebyscore` replies wait on the replay.

- Reschedule: `job:1` is queued in the past. Once the take's read answers, a second client sends `ZADD job:1` an hour later, then the batch goes on. The sync build ran the handler once and kept `job:1` at its new score. The reverted build ran it once and left the queue empty.
- Two listeners: two scheduler instances, each loaded fresh with its own client, call `runTasks` together, and each read is held until both have answered. The sync build ran the handler once (`["l1:1"]`). The reverted build ran it twice (`["l1:1","l2:1"]`).
