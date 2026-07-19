---
name: redis-scheduler-interface
description: Distributed Redis-backed task scheduling for AntelopeJS - register named handlers, schedule tasks at a due timestamp in a Redis sorted set, and execute them with automatic retries coordinated across instances via pub/sub. Use when code imports '@antelopejs/interface-redis-scheduler', when a task involves scheduling delayed/deferred jobs, reminders, or background work in an AntelopeJS module, or when symbols like setHandler, addTask, removeTask, enableListener, disableListener, or the SchedulerUtil.Tasks Redis key appear.
category: antelopejs-interface
tags: [antelopejs, redis, scheduler, tasks, background-jobs]
---

# Redis Scheduler Interface

Distributed task scheduler on top of Redis: tasks live in one sorted set
(`SchedulerUtil.Tasks`) scored by their due timestamp; listener instances
coordinate through the `SchedulerUtil` pub/sub channel. Mental model: this is a
consumer-side utility, not a proxied service. All exported functions run in
your own module; Redis access goes through `GetClient()` from
`@antelopejs/interface-redis` (`setHandler` itself is purely local, no Redis
call) - there is no provider to write with
`ImplementInterface`. A Redis interface implementation (e.g. the
`@antelopejs/redis` module) must be loaded in the app.

## Imports

Only the package root is exported:

```typescript
import {
  setHandler,
  enableListener,
  disableListener,
  addTask,
  removeTask,
} from "@antelopejs/interface-redis-scheduler";
```

(`updateTimer` and `runTasks` are also exported but belong to the internal
execution loop - only call them in tests or advanced scenarios.)

## Consumption example

```typescript
import {
  setHandler,
  enableListener,
  disableListener,
  addTask,
} from "@antelopejs/interface-redis-scheduler";

// 1. Register handlers first (name must not contain ':')
setHandler("send-email", async (taskInfo) => {
  const data = JSON.parse(taskInfo);
  await sendEmail(data.to, data.subject, data.body);
});

// 2. Start the execution loop (module start)
await enableListener();

// 3. Schedule a task: dueTime is a Unix timestamp in milliseconds
await addTask(
  "send-email",
  Date.now() + 60 * 60 * 1000,
  JSON.stringify({ to: "a@b.c", subject: "Hi", body: "Hello" }),
);

// 4. On shutdown
await disableListener();
```

## Gotchas

- Handler names must not contain `:` - it delimits the sorted-set member
  format `handlerName:taskInfo`. `setHandler` throws otherwise.
- `addTask` and `removeTask` throw for handler names not registered in the
  current process. Always call `setHandler` before scheduling.
- Register all handlers before `enableListener()`; the listener starts
  executing due tasks immediately.
- `taskInfo` is a plain string. Serialize/parse (typically JSON) yourself.
- `removeTask` needs the exact original `taskInfo` string; a JSON payload with
  different key order or whitespace fails to match, silently removing nothing.
- Failed handlers are retried up to 3 times with a 5-second delay (the member
  becomes `RETRY-{n}:handlerName:taskInfo`), then discarded; errors are logged
  through interface-core `Logging.Error`.
- `enableListener` duplicates the shared Redis client into a dedicated
  subscriber connection; `disableListener` quits that subscriber on shutdown.
- `disableListener` only quits the subscriber connection; it does not clear a
  pending execution timer, so a task that comes due right after shutdown may
  still run once. It also throws if `enableListener` was never called.
- Peer interfaces `@antelopejs/interface-core` and `@antelopejs/interface-redis`
  must be installed alongside this package.

## Deeper reference

See this package's `docs/1.introduction.md` (Overview, Getting Started, Core
Concepts, per-function sections, Retry Logic, Redis Storage, Complete Example)
and `dist/index.d.ts`. Do not duplicate them here.
