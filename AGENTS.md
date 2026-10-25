# interface-redis-scheduler

The AntelopeJS interface for scheduling tasks on Redis, published as `@antelopejs/interface-redis-scheduler`. The whole contract lives in `src/index.ts`. Unlike a proxied interface, every exported function runs in the consumer's module and reaches Redis through `GetClient()` from `@antelopejs/interface-redis`; a Redis implementation such as `@antelopejs/redis` (its own repository) must be loaded in the app.

## Versioning

`@antelopejs/interface-core` and `@antelopejs/interface-redis` are peer dependencies with a `>=minimum <1.0.0` range. The devDependency on each pins the same minimum. When you raise a minimum, raise the peer range, the devDependency, and the compatibility table in `README.md` together; the docs check compares that table with `peerDependencies` through its `docs-compat` marker.

The Redis key `SchedulerUtil.Tasks`, the `SchedulerUtil` pub/sub channel and the `<handler>:<info>` member format with its `RETRY-<n>:` prefix on re-queued retries are shared by every running instance. Changing any of them is a breaking change for deployed apps with queued tasks.

## Tests

- `pnpm test` builds `dist`, then runs `ajs module test .`. `src/antelope.test.ts` (`antelopeJs.test` in `package.json`) describes the test project: it installs `@antelopejs/redis` 1.0.3 from npm with `useMock: true`, so no Redis server is needed, and runs the compiled suites in `dist/tests`. The suites are written in `src/tests`.
- `ajs module test` installs each module with corepack and the `packageManager` that module pins (`pnpm@10.6.5` for `@antelopejs/redis` 1.0.3) when corepack is on `PATH`, and with the `pnpm` on `PATH` otherwise. Node 25 and later do not bundle corepack, so there install pnpm 10.6.5 another way.
- `pnpm run checks` does not run the documentation check. CI runs it through the `docs-files` input in `.github/workflows/ci.yml`. To run it locally, clone `AntelopeJS/tooling-configs` at `v0.0.9` (the ref ci-node pins), run `npm ci --prefix actions/docs --omit=dev`, then run `node <clone>/actions/docs/check.mjs --files "$(printf 'README.md\ndocs')"` from this repository.

## Shipped files

`docs/` and `skills/` ship in the npm package. `docs/` holds the guides the package `homepage` (interfaces.antelopejs.com/docs/redis-scheduler) points to. `skills/` reaches users through `antelopeJs.skills`; when the contract changes, update `skills/redis-scheduler-interface/SKILL.md`.

<!-- antelopejs-guardrails:start -->
<!-- Managed by @antelopejs/tooling-configs. `antelopejs-sync` rewrites everything between these markers; write repository-specific guidance outside them. -->

## Guardrails

Finish every change with `pnpm run checks`. It runs typecheck, lint, format, knip, tests, size, ratchet, and sync, and prints only what failed. The change is done when it prints no failure.

The tools enforce most rules, listed in the table at the end. The sections below hold the rules no tool checks.

### Comments

Say it in code. A constraint belongs in a type, a lint rule, or a test. A public item's contract belongs in TSDoc (`/** */`) on that item. The only other comments are lint directives that name their rules, `@ts-expect-error <reason>`, `SAFETY: <reason>` above a type assertion, `/*!` license headers, and bundler or formatter directives.

### Tests

Hold every test you write or keep to this checklist:

- Name the wrong implementation this test fails on. A test with no answer is deleted, not kept.
- No test reads the file it tests. Drive the behaviour through the public interface.
- An invariant over many files is a lint rule, not a test.

### Debt

`guardrails.ratchet.json` records the lint findings and oversize files this repository already had. Its numbers only go down. After you remove debt, run `pnpm run ratchet:update` and commit the lowered file. A rule listed there is off for `oxlint`. The ratchet counts it instead, and the pre-commit hook rejects it on every line you add.

### What enforces what

| Rule                                                                           | Enforced by                               |
| ------------------------------------------------------------------------------ | ----------------------------------------- |
| Formatting                                                                     | oxfmt                                     |
| Lint findings are errors; no rule warns                                        | oxlint preset                             |
| Comments are TSDoc, directives, or `SAFETY:` only                              | `antelopejs/no-comments`                  |
| Every test asserts                                                             | `antelopejs/require-assertion`            |
| Tests read no files outside fixtures, helpers, locales                         | `antelopejs/no-fs-read-in-tests`          |
| No assertion that restates a constant                                          | `antelopejs/no-constant-value-assertion`  |
| No test whose only check is "is a function"                                    | `antelopejs/no-typeof-function-only-test` |
| Params ≤ 5, function ≤ 120 lines, file ≤ 500 lines, depth ≤ 4, complexity ≤ 20 | `eslint/max-*`, `eslint/complexity`       |
| Files ≤ 20,000 bytes, tests included                                           | `antelopejs-check-size` (pre-commit)      |
| Existing debt only shrinks                                                     | `antelopejs-ratchet`                      |
| Types check                                                                    | `tsc` (pre-push)                          |
| No dead files, exports, or dependencies                                        | knip                                      |
| Managed files match the pack                                                   | `antelopejs-sync --check`                 |
| A test names the wrong implementation it catches                               | review; no tool                           |

<!-- antelopejs-guardrails:end -->
