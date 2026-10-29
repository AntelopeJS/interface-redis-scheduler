---
covers:
docs:
  - docs/1.introduction.md
journeys:
  - queue-members
  - due-delivery
  - minor-bump
---

# Smoke

The fixed journeys every verdict runs, whatever the diff touches: queue and cancel a task in a live Redis, run a due one, and compare the declared functions with the published version.

## Sub-features

- `queue-members`: as in [queue](queue.md).
- `due-delivery`: as in [delivery](delivery.md).
- `minor-bump`: an added, changed or removed function releases as at least a new minor.

## How to get to it (user POV)

- A project with a Redis implementation and a module that imports `@antelopejs/interface-redis-scheduler`.

## Driving it with antelopejs-verify

```bash
pnpm exec antelopejs-verify journey "$RUN" smoke
```

## Gotchas

- The smoke feature covers no glob, so it never marks a file as mapped.
- `minor-bump` needs the npm registry; without it the journey is not verified.
