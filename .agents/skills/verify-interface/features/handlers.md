---
covers:
  - src/index.ts
docs:
  - docs/1.introduction.md
journeys:
  - handler-names
  - signatures
---

# Handlers

`setHandler(handlerName, handler)` registers the function that runs tasks of one type. A name containing `:` is refused, because `:` separates the handler from the payload in a queued member.

## Sub-features

- `handler-names`: `setHandler("a:b", ...)` throws "SchedulerUtil handler name may not contain `:`"; `setHandler("fine-name", ...)` is accepted and `addTask` for it stores `fine-name:ok`.
- `signatures`: a probe compiled in strict mode against the packed declarations requires each of the seven exports to have exactly the signature `docs/1.introduction.md` documents (`setHandler(handlerName: string, handler: (taskInfo: string) => void | Promise<void>): void`, `addTask(handlerName, dueTime: number, taskInfo): Promise<void>`, and so on).

## How to get to it (user POV)

- `setHandler("send-email", async (taskInfo) => { ... })` before any `addTask` or `enableListener`, in every process that enqueues or runs the type.

## Driving it with antelopejs-verify

```bash
pnpm exec antelopejs-verify journey "$RUN" handlers
```

## Gotchas

- Handlers live in memory of the registering process; the journey registers them in the scenario's own process.
