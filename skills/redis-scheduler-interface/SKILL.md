---
name: redis-scheduler-interface
description: Distributed Redis-backed task scheduling for AntelopeJS. Register named handlers, schedule tasks at a due timestamp in a Redis sorted set, and execute them with automatic retries; listeners across instances claim due tasks atomically, and pub/sub only re-arms their timers. Use when code imports '@antelopejs/interface-redis-scheduler', when a task involves scheduling delayed/deferred jobs, reminders, or background work in an AntelopeJS module, or when symbols like setHandler, addTask, removeTask, enableListener, disableListener, or the SchedulerUtil.Tasks Redis key appear.
category: antelopejs-interface
tags: [antelopejs, redis, scheduler, tasks, background-jobs]
---

# Redis Scheduler Interface

Distributed task scheduler on top of Redis. Tasks live in one sorted set
(`SchedulerUtil.Tasks`), scored by their due timestamp. A listener takes the
due tasks with one Lua script that reads and removes them in a single step, so
each due entry goes to exactly one listener, and several listeners can share
the queue. The `SchedulerUtil` pub/sub channel only carries an `update`
message that tells listeners to re-arm their timers; it does not decide who
runs a task.

Mental model: this is a consumer-side utility, not a proxied service. All
exported functions run in your own module. Redis access goes through
`GetClient()` from `@antelopejs/interface-redis` (`setHandler` itself is local
and makes no Redis call). There is no provider to write with
`ImplementInterface`. A Redis interface implementation (for example the
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

`updateTimer` and `runTasks` are also exported, but they belong to the internal
execution loop. Call them only in tests or advanced scenarios.

## Consumption example

```typescript
import {
  setHandler,
  enableListener,
  disableListener,
  addTask,
} from "@antelopejs/interface-redis-scheduler";

// 1. Register handlers first (name must not contain ':')
setHandler("overdue-notice", async (taskInfo) => {
  const data = JSON.parse(taskInfo);
  await notifyMember(data.memberId, data.bookTitle);
});

// 2. Start the execution loop (module start)
await enableListener();

// 3. Schedule a task: dueTime is a Unix timestamp in milliseconds
await addTask(
  "overdue-notice",
  Date.now() + 60 * 60 * 1000,
  JSON.stringify({ memberId: "M-1042", bookTitle: "The Heron's Atlas" }),
);

// 4. On shutdown
await disableListener();
```

## Gotchas

- Handler names must not contain `:`, which delimits the sorted-set member
  format `handlerName:taskInfo`. `setHandler` throws otherwise.
- `addTask` and `removeTask` reject with `Unknown SchedulerUtil handler: <name>`
  for a handler name not registered in the current process. Call `setHandler`
  before you schedule.
- Register every handler in every listener process. A listener that claims a
  due entry whose handler it has not registered drops the entry: it does not
  run it, retry it or log it.
- Register all handlers before `enableListener()`. The listener checks for due
  tasks as soon as it starts.
- A claimed entry is removed from Redis before its handler runs. If the
  process stops during the run, the task is lost. There is no exactly-once
  execution.
- A batch runs its handlers one after another, earliest due time first.
- One process runs one batch at a time, so its handlers never overlap. A
  `runTasks()` call while a batch runs returns at once; that batch picks up
  the tasks that fell due meanwhile when it resolves. A batch that rejects
  arms no timer, so those tasks wait for the next update message.
- `taskInfo` is a plain string. Serialize and parse it (typically JSON)
  yourself.
- `removeTask` needs the exact original `taskInfo` string. A JSON payload with
  a different key order or whitespace does not match, and nothing is removed.
- A handler that throws or rejects is retried up to 3 times. Each retry is due
  5 seconds after the attempt that failed, and its member becomes
  `RETRY-{n}:handlerName:taskInfo`. After the third retry fails, the task is
  discarded. When Redis rejects the retry write, that task gets no retry and
  the batch runs its next task. Every failure is logged through
  interface-core `Logging.Error`.
- The listener's timer waits at most 24 hours before it checks again. It does
  not keep the process alive on its own: a process with nothing else pending
  exits, and its queued tasks stay in Redis for the next listener.
- `enableListener` duplicates the shared Redis client into a dedicated
  subscriber connection. `disableListener` quits that subscriber.
- `disableListener` only quits the subscriber connection. It does not clear
  the pending timer, cancel running handlers, or wait for tasks to complete.
  An armed timer keeps running due tasks and arming the next timer through
  `updateTimer()`, so tasks can keep running after it returns. Do not use it as
  a pause, a drain, or a guarantee that no more tasks run: the public API has
  no operation that stops the timer. It rejects if `enableListener` was never
  called.
- Peer interfaces `@antelopejs/interface-core` and `@antelopejs/interface-redis`
  must be installed alongside this package.

## Deeper reference

See this package's `docs/1.introduction.md` (overview, getting started, core
concepts, one section per function, retry logic, Redis storage, complete
example, known limitations) and `dist/index.d.ts`. Do not duplicate them here.
