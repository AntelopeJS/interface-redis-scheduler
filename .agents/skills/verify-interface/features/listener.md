---
covers:
  - src/index.ts
docs:
  - docs/1.introduction.md
journeys:
  - listener-timer
---

# Listener

`enableListener()` opens a dedicated Redis subscriber on the `SchedulerUtil` channel and arms a timer for the earliest task; `addTask` publishes `update` so listeners re-arm. `disableListener()` closes the subscriber only (it does not stop the timer).

## Sub-features

- `listener-timer`: with the listener enabled, a task added for 1.5 seconds ahead has not run after 0.7 seconds, has run exactly once after 3.2 seconds (between 1.4 and 3.5 seconds after it was added) and has left the sorted set; `disableListener()` resolves.

## How to get to it (user POV)

- `await enableListener()` once handlers are registered, then `addTask(...)` from any process sharing the Redis.

## Driving it with antelopejs-verify

```bash
pnpm exec antelopejs-verify journey "$RUN" listener
```

## Gotchas

- The journey takes about four seconds of wall time.
- It cannot show that `disableListener()` leaves the timer armed (documented behaviour), only that it resolves.
