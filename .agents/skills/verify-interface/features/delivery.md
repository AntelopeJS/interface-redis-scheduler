---
covers:
  - src/index.ts
docs:
  - docs/1.introduction.md
journeys:
  - due-delivery
  - retry-chain
---

# Delivery

`runTasks()` takes every due member out of the sorted set (read and removed in one Lua script) and calls the matching handler with the payload. A handler that throws is reported through `Logging.Error` and re-queued as `RETRY-<n>:handlerName:taskInfo` five seconds later, up to three retries (four attempts), then discarded.

## Sub-features

- `due-delivery`: a past-due `echo:p:q:r` reaches its handler once with `p:q:r` (the payload keeps its colons) and leaves the set; a task due in 2100 stays queued. Redis is read back through `redis-cli`.
- `retry-chain`: a handler that always throws turns `flaky:job` into `RETRY-1:flaky:job`, then `RETRY-2`, then `RETRY-3`, each scored 4 to 6.5 seconds ahead, and the fourth failure leaves the set empty after four handler calls in total.

## How to get to it (user POV)

- A listener fires `runTasks()` when the timer elapses; `runTasks()` can also be awaited directly ("advanced usage" in the docs).

## Driving it with antelopejs-verify

```bash
pnpm exec antelopejs-verify journey "$RUN" delivery
```

## Gotchas

- The documented limits (no exactly-once delivery, a crash after removal loses the task) are not journeys: they describe what is not promised.
- `Logging.Error` writes the thrown errors to the scenario's output; they are expected.
