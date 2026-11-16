# interface-redis-scheduler

The AntelopeJS interface for scheduling tasks on Redis, published as `@antelopejs/interface-redis-scheduler`. The whole contract lives in `src/index.ts`. Unlike a proxied interface, every exported function runs in the consumer's module and reaches Redis through `GetClient()` from `@antelopejs/interface-redis`; a Redis implementation such as `@antelopejs/redis` (its own repository) must be loaded in the app.

## Versioning

`@antelopejs/interface-core` and `@antelopejs/interface-redis` are peer dependencies whose range stops below the next minor (`>=0.5.1 <0.6.0`). The devDependency on each uses the same range. The `dependency:ranges` step of `pnpm run checks` rejects any `@antelopejs/*` range on 0.x that does not stop below the next minor, and any range on 1.x that does not use `~`. When you raise a minimum, raise the peer range, the devDependency, and the compatibility table in `README.md` together; the docs check compares that table with `peerDependencies` through its `docs-compat` marker.

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

CI runs `pnpm run checks` in full on every pull request and reports what failed. The commit hook formats and lints the staged files. Locally, run only the fast check for what you touched:

- `pnpm run typecheck` after you change types or signatures.
- `pnpm exec oxlint <files>` and `pnpm exec oxfmt <files>` on the files you changed.
- One test file, not the suite. In a module that tests with `ajs module test`: `pnpm run build`, then `pnpm exec ajs module test . -f dist/<path>.test.js`.

### Comments

Say it in code: a constraint in a type, a lint rule or a test, a public item's contract in TSDoc. Other comments are lint directives naming their rules, `@ts-expect-error <reason>`, `SAFETY: <reason>` above a type assertion, and license or tool directives. A reason states what the code does now.

### Tests

Each test names the wrong implementation it fails on, or is deleted. Drive behaviour through the public interface. An invariant over many files is a lint rule.

### Review

No tool checks these:

- A type guard checks the nested elements and values it claims.
- A no-upward import rule rejects same-tier peers; probe it with an import.
- A finding only an evasion or a patched internal can trigger goes under Attention and never blocks.

### Suppressions

`guardrails.suppressions.json` caps lint directives, `@ts-expect-error`, `SAFETY:` comments and rules a lint config turns off. Over a cap, fix the code or remove another suppression of that kind; only the operator raises a number. After removing suppressions, run `pnpm run suppressions:update` and commit the file.

<!-- antelopejs-guardrails:end -->
