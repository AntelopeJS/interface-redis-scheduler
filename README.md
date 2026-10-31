# @antelopejs/interface-redis-scheduler

<div align="center">
<a href="https://www.npmjs.com/package/@antelopejs/interface-redis-scheduler"><img alt="npm" src="https://img.shields.io/npm/v/@antelopejs/interface-redis-scheduler?style=for-the-badge&labelColor=000000&color=000000"></a>
<a href="./LICENSE"><img alt="License" src="https://img.shields.io/npm/l/@antelopejs/interface-redis-scheduler?style=for-the-badge&labelColor=000000&color=000000"></a>
<a href="https://discord.gg/kxzZMWqdFU"><img alt="Discord" src="https://img.shields.io/badge/Discord-18181B?logo=discord&style=for-the-badge&color=000000"></a>
<a href="https://interfaces.antelopejs.com/docs/redis-scheduler"><img alt="Docs" src="https://img.shields.io/badge/Docs-18181B?style=for-the-badge&color=000000"></a>
</div>

Task scheduling on Redis for AntelopeJS: schedule a task for a given time, and the application runs it when it is due, with up to three retries on failure.

## What it offers

- `setHandler` registers the function that runs one kind of task.
- `addTask` schedules a task for a Unix timestamp in milliseconds; `removeTask` cancels it.
- `enableListener` starts task processing; `disableListener` closes only the notification subscriber, not the pending timer.
- Tasks live in a Redis sorted set, so they survive restarts and every instance of the application sees the same queue.

## Implementations

| Module                                                     | Notes                                         |
| ---------------------------------------------------------- | --------------------------------------------- |
| [`@antelopejs/redis`](https://github.com/AntelopeJS/redis) | Also implements `@antelopejs/interface-redis` |

## Install

Add the interface to the module that schedules tasks:

```bash
pnpm add @antelopejs/interface-redis-scheduler
```

Then add the implementation to the project:

```bash
ajs project modules add @antelopejs/redis
```

## Quick start

```ts
import { Logging } from "@antelopejs/interface-core/logging";
import {
  addTask,
  disableListener,
  enableListener,
  setHandler,
} from "@antelopejs/interface-redis-scheduler";

const ONE_HOUR_MS = 60 * 60 * 1000;

setHandler("overdue-notice", async (taskInfo) => {
  const { memberId } = JSON.parse(taskInfo);
  Logging.Info(`Remind member ${memberId}`);
});

export async function start() {
  await enableListener();
  await addTask(
    "overdue-notice",
    Date.now() + ONE_HOUR_MS,
    JSON.stringify({ memberId: "M-1042" }),
  );
}

export async function stop() {
  await disableListener();
}
```

Register a handler before you schedule tasks for it: `addTask` throws for an unknown handler name.

`disableListener()` is not a full shutdown or pause: a pending timer and running handlers can continue processing tasks. See the [current lifecycle and delivery limitations](./docs/1.introduction.md#disablelistener) before using it for shutdown.

## Documentation

- [Introduction and scheduler reference](./docs/1.introduction.md)

## Compatibility

Requires AntelopeJS core `1.x` and the following peer dependencies:

<!-- antelopejs-docs-compat:start -->

| Package                       | Supported        | Tested with |
| ----------------------------- | ---------------- | ----------- |
| `@antelopejs/interface-core`  | `>=0.2.4 <1.0.0` | `0.2.4`     |
| `@antelopejs/interface-redis` | `>=0.0.9 <1.0.0` | `0.0.9`     |

<!-- antelopejs-docs-compat:end -->

## Contributing

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before you open a pull request. The local checks are:

```bash
pnpm install
pnpm lint
pnpm test
```

## License

[Apache-2.0](./LICENSE)
