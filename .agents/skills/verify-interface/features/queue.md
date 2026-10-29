---
covers:
  - src/index.ts
docs:
  - docs/1.introduction.md
journeys:
  - queue-members
---

# Queue

A module calls `addTask(handlerName, dueTime, taskInfo)` to store a task in the Redis sorted set `SchedulerUtil.Tasks` (member `handlerName:taskInfo`, score the due time in milliseconds) and `removeTask(handlerName, taskInfo)` to remove the exact member. Both throw `Unknown SchedulerUtil handler: <name>` for a name no `setHandler` registered.

## Sub-features

- `queue-members`: against a live Redis (Docker) with a Redis client handed to `interface-redis`: `addTask` stores `mail:a:b` (a colon in the payload is kept) at its due score; adding the same pair again would move it, not duplicate it; an unknown handler rejects both calls with the documented message; `removeTask` removes exactly the member and ignores one that was never added. The sorted set is read back with `redis-cli zrange ... withscores`.

## How to get to it (user POV)

- `await addTask("send-email", Date.now() + 3 * 24 * 3600 * 1000, savedPayload)` and `await removeTask("send-email", savedPayload)`.

## Driving it with antelopejs-verify

```bash
pnpm exec antelopejs-verify journey "$RUN" queue
```

## Gotchas

- Needs Docker: each journey starts its own `redis:7-alpine` container on a free loopback port and removes it before it ends (the interface kind of the harness starts no services, so `clean` does not know it).
- The scenario runs the packed `dist/index.js` in a Node process, not inside `ajs project dev`: the scheduler needs a Redis client, which the stub provider of the shared journeys cannot supply, so `every-function` is not part of this map.
