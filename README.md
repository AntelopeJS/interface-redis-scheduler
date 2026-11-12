<a href="https://github.com/AntelopeJS/antelopejs"><img data-illustration src="./.github/readme/strip.svg" width="100%" alt="INTERFACE · REDIS SCHEDULER: part of AntelopeJS, hexagonal architecture beyond your own code. A glowing button reads Star AntelopeJS."></a>

<div align="center">

# `@antelopejs/interface-redis-scheduler`

<a href="https://www.npmjs.com/package/@antelopejs/interface-redis-scheduler"><img data-illustration alt="npm" src="https://img.shields.io/npm/v/@antelopejs/interface-redis-scheduler?style=for-the-badge&labelColor=000000&color=000000"></a> <a href="./LICENSE"><img data-illustration alt="License" src="https://img.shields.io/npm/l/@antelopejs/interface-redis-scheduler?style=for-the-badge&labelColor=000000&color=000000"></a> <a href="https://discord.gg/g4pFt6eXqu"><img data-illustration alt="Discord" src="https://img.shields.io/badge/Discord-18181B?logo=discord&style=for-the-badge&color=000000"></a> <a href="https://interfaces.antelopejs.com/docs/redis-scheduler"><img data-illustration alt="Documentation" src="https://img.shields.io/badge/Docs-18181B?style=for-the-badge&color=000000"></a> <a href="https://github.com/AntelopeJS/antelopejs"><img data-illustration alt="Star AntelopeJS" src="https://img.shields.io/github/stars/AntelopeJS/antelopejs?label=Star%20AntelopeJS&style=for-the-badge&labelColor=000000&color=000000&logo=github"></a>

**Task scheduling on Redis for AntelopeJS. Schedule a task for a given time and the application runs it when due, with up to three retries.**

[Documentation](https://interfaces.antelopejs.com/docs/redis-scheduler) · [Implementations](#implementations) · [All interfaces and providers](https://github.com/AntelopeJS/antelopejs#ecosystem)

</div>

Task scheduling on Redis for AntelopeJS. You schedule a task for a given time, and a listener in your application runs it when it is due, with up to three retries on failure.

## What it offers

- `setHandler` registers the function that runs one kind of task.
- `addTask` schedules a task for a Unix timestamp in milliseconds. `removeTask` removes the queued entry before it runs.
- `enableListener` starts task processing. `disableListener` closes only the notification subscriber, not the pending timer.
- Tasks live in a Redis sorted set, so they survive application restarts and every instance of the application sees the same queue. Each due task goes to one listener.

## Implementations

| Module                                                     | Notes                                                                                             |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [`@antelopejs/redis`](https://github.com/AntelopeJS/redis) | Also implements `@antelopejs/interface-redis`, which supplies the Redis client the scheduler uses |

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

Register a handler before you schedule tasks for it. `addTask` rejects for a handler name that this process has not registered.

`disableListener()` is not a full shutdown or pause. A pending timer and running handlers can continue to process tasks. Read the [lifecycle and delivery limits](./docs/1.introduction.md#disablelistener) before you use it for shutdown.

## Documentation

- [Introduction and scheduler reference](./docs/1.introduction.md)

## Compatibility

The module declares these peer dependencies:

<!-- antelopejs-docs-compat:start -->

| Package                       | Supported        | Tested with |
| ----------------------------- | ---------------- | ----------- |
| `@antelopejs/interface-core`  | `>=0.2.4 <1.0.0` | `0.4.0`     |
| `@antelopejs/interface-redis` | `>=0.0.9 <1.0.0` | `0.0.9`     |

<!-- antelopejs-docs-compat:end -->

## Contributing

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before you open a pull request. The local checks are:

```bash
pnpm install
pnpm lint
pnpm test
```

## Part of AntelopeJS

This package belongs to [AntelopeJS](https://github.com/AntelopeJS/antelopejs), the TypeScript framework where modules depend on contracts and the application chooses the provider. The open-source back office [AntelopeJS DMS](https://github.com/AntelopeJS/dms) is built on it.

<!-- antelopejs-framework-modules:start -->

| Area         | Contracts                                                                                                                                                                                                                                                                                                                                                                                                                  | Providers                                                                                                                                                                                                                                           |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| API          | [`interface-api`](https://github.com/AntelopeJS/interface-api) · [`interface-api-util`](https://github.com/AntelopeJS/interface-api-util) · [`interface-data-api`](https://github.com/AntelopeJS/interface-data-api)                                                                                                                                                                                                       | [`api`](https://github.com/AntelopeJS/api)                                                                                                                                                                                                          |
| Auth         | [`interface-auth`](https://github.com/AntelopeJS/interface-auth)                                                                                                                                                                                                                                                                                                                                                           | [`auth-jwt`](https://github.com/AntelopeJS/auth-jwt)                                                                                                                                                                                                |
| Database     | [`interface-database`](https://github.com/AntelopeJS/interface-database) · [`interface-database-decorators`](https://github.com/AntelopeJS/interface-database-decorators) · [`interface-database-catalog`](https://github.com/AntelopeJS/interface-database-catalog) · [`interface-mongodb`](https://github.com/AntelopeJS/interface-mongodb) · [`interface-rethinkdb`](https://github.com/AntelopeJS/interface-rethinkdb) | [`postgres`](https://github.com/AntelopeJS/postgres) · [`mongodb`](https://github.com/AntelopeJS/mongodb) · [`rethinkdb`](https://github.com/AntelopeJS/rethinkdb)                                                                                  |
| Redis        | [`interface-redis`](https://github.com/AntelopeJS/interface-redis) · **`interface-redis-scheduler`**                                                                                                                                                                                                                                                                                                                       | [`redis`](https://github.com/AntelopeJS/redis)                                                                                                                                                                                                      |
| Email        | [`interface-email`](https://github.com/AntelopeJS/interface-email)                                                                                                                                                                                                                                                                                                                                                         | [`nodemailer`](https://github.com/AntelopeJS/nodemailer) · [`brevo`](https://github.com/AntelopeJS/brevo)                                                                                                                                           |
| File storage | [`interface-file-storage`](https://github.com/AntelopeJS/interface-file-storage)                                                                                                                                                                                                                                                                                                                                           | [`file-storage-local`](https://github.com/AntelopeJS/file-storage-local) · [`file-storage-s3`](https://github.com/AntelopeJS/file-storage-s3)                                                                                                       |
| Payments     | [`interface-payment`](https://github.com/AntelopeJS/interface-payment) · [`interface-subscriptions`](https://github.com/AntelopeJS/interface-subscriptions) · [`interface-stripe`](https://github.com/AntelopeJS/interface-stripe)                                                                                                                                                                                         | [`stripe`](https://github.com/AntelopeJS/stripe) · [`mollie`](https://github.com/AntelopeJS/mollie) · [`checkout-com`](https://github.com/AntelopeJS/checkout-com) · [`payment-subscriptions`](https://github.com/AntelopeJS/payment-subscriptions) |

<!-- antelopejs-framework-modules:end -->

## License

[Apache-2.0](./LICENSE)
