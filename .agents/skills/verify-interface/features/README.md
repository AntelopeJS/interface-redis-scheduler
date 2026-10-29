# Feature map

One file per feature. `covers:` lists the source globs it owns, `docs:` the pages a verdict judges, `journeys:` the journeys it runs, and `seeded-breaks/<feature>.patch` the break its journeys must catch. `pnpm exec antelopejs-verify map` checks that every user-facing file is covered.

| Feature | What the user does | Journeys |
|---|---|---|
| [queue](queue.md) | A module queues a task for a later time, and cancels it. | queue-members |
| [handlers](handlers.md) | A module registers the task types it can run, by name. | handler-names, signatures |
| [delivery](delivery.md) | Due tasks run their handler once, and a failing handler is retried. | due-delivery, retry-chain |
| [listener](listener.md) | A module turns the scheduler on, and tasks run when they fall due. | listener-timer |
| [smoke](smoke.md) | The fixed journeys every verdict runs: queue a task, run a due one, check the release rule. | queue-members, due-delivery, minor-bump |
