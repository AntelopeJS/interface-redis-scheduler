---
name: verify-interface
description: "Drive this AntelopeJS interface the way a module author does: pack it, load it in `ajs project dev` next to a stub provider wired through ImplementInterface and a consumer, call every declared function through core, and check the minor-bump rule against the published version. Use to prove a change to the interface works before merge, or to verify a PR."
---

# Verify interface

The user of an interface is a module author: one module implements it, others import it and call its functions through core. Every deterministic step is an `antelopejs-verify` command: you choose which journeys to run and judge what they show. Never replace a command with a shell recipe. When a journey you need does not exist, add it to `verify.config.ts`, name it in its feature file, then run it.

`antelopejs-sync` writes this file, `package.json` and `tsconfig.json` here, and keeps them in sync. Everything else in `.agents/skills/verify-interface/` is the repository's own layer, which sync never touches.

## Launch

```bash
node_modules/.bin/antelopejs-verify new --base origin/main --title "<PR title>"
```

`new` prints the run folder; pass it as `<run>` below. `new` runs the setup (`pnpm run build` by default), then packs the interface with `pnpm pack` and extracts it, so journeys load what npm would publish, `files` and `exports` included. Every `services` entry of `verify.config.ts` then starts in its own Docker container on a free loopback port, as for a module. Every journey gets its own `HOME` and scratch folder, `CI=1`, `AJS_NO_UPDATE_CHECK=1`, `NO_COLOR=1` and a free port from the kernel, so two runs never share an instance. Run it from the repository root after installing dependencies.

## Doctor

```bash
node_modules/.bin/antelopejs-verify doctor <run>
```

Doctor checks that HEAD has not moved since `new`, `ajs` comes from the repository's `@antelopejs/core`, the build is newer than `src/`, what `new` prepared is there, and no process the run recorded is still alive. Do not drive a run that fails doctor.

## Drive

```bash
node_modules/.bin/antelopejs-verify plan --base origin/main
node_modules/.bin/antelopejs-verify journey <run> --plan
```

`plan` maps the diff to features and lists unmapped surfaces. `journey <run> --plan` runs every feature `plan` lists as `run` for the run's base, `smoke` first, in one call: it prints each feature's lines in turn, keeps going after a feature fails, and exits 1 when any journey did not pass. Run it once instead of one call per feature.

Features run one after another by default. When verify.config.ts declares no `services`, use `--jobs 4` when the machine is otherwise idle (load below the core count); otherwise run sequentially. `--jobs` runs up to that many features at once, each in a process of its own, capped at half the machine's cores; it finishes sooner but costs about twice the CPU time. The output, the evidence and the exit code are those of the sequential call, and a feature that lists a journey an earlier feature lists waits for it, so it still reuses that PASS. A feature whose process dies or leaves an uncaught error is named on stderr, and the others still run. On an interrupt, a feature's process that has not stopped 5 s later, or at a second interrupt, is killed with the apps it started; the call prints every feature that ended and names the rest in `not run: <features>`. `--jobs` above 1 is refused when verify.config.ts declares `services`, because each journey resets them as it starts, which would wipe the data of a journey running beside it. Without `--jobs`, a journey that leaves an uncaught error behind ends the call and the line `not run: <features>` names what to rerun.

To rerun after a fix, run one feature, or only the journeys you name, or several features by name, with `--jobs` too:

```bash
node_modules/.bin/antelopejs-verify journey <run> <feature> [journey...]
node_modules/.bin/antelopejs-verify journey <run> --features <feature>,<feature> [--jobs 4]
```

The pack ships these journeys for this kind; a feature file names them next to the repository's own:

- `every-function`: a fixture project loads the packed interface with a stub provider and a consumer module. The consumer walks the loaded interface, and every function the `.d.ts` files declare is called through core:
  - an async proxy answers the stub's echo, and the stub's call log shows the same arguments (the second view);
  - a registering proxy registers and unregisters, and the stub logs both;
  - an event proxy delivers the emitted arguments to a registered handler;
  - a plain function runs the `interface.calls` hook of `verify.config.ts` and must return its `expect`; one only providers call is listed in `interface.providerSide` with why.
  A declared function with none of these fails the journey.
- `minor-bump`: reads the declared functions of the packed head and of the published version (`npm pack <name>@<latest>`). An added, changed or removed function needs a release of at least the next minor. The release is the head version when it is already bumped, otherwise what changelogen makes of the change title (`new --title`) or the commit subjects since the base.

## Evidence

Each step writes `<run>/evidence/<feature>/<journey>/<NN-step>/` with `command.txt`, `stdout.txt`, `stderr.txt`, `exit-code.txt`, `pid.txt` for background processes, `tree.txt`, `http.json` for every request, and `checks.json`. `result.json` holds a journey's result and `feature.json` the merged results of the feature. A journey id listed under two features runs once per run: when a feature runs without named ids, from `--plan`, `--features` or `journey <run> <feature>`, and another feature of the run already passed that id at the same HEAD, the feature records a result with `reusedFrom` naming that evidence folder and runs nothing. Name the id to run it again. Read the evidence before you judge a PASS: a check proves only what it asserts.

## Cleanup

```bash
node_modules/.bin/antelopejs-verify clean <run>
```

Each journey deletes its scratch folder and `HOME`, its install included, when it ends: passed, failed or interrupted. Only its evidence stays. `clean` stops what the run started, by recorded PID and container name, and removes everything but `evidence/` and `run.json`, the folders `context.prepared` kept included. Run it after every run, failed ones included.

## The repository's own layer

- `verify.config.ts` default-exports a `VerifyConfig` from `@antelopejs/tooling-configs/verify`:
  - `doors`: one entry per door kind (`data`, `format`, `contract`, `outbound`, `exposure`, `publish`), each `null` when it cannot apply or `{ globs, funnels, why }`.
  - `journeys`: the repository's journeys by id, each `{ title, entryPoint, run(context) }`, using the check helpers the same import exports. A check states what the product must do; an environment that went away is never a failing check. When a journey fails, the harness reruns each service's readiness command, up to four times over about 3.5 s, and looks at every `ajs project dev` the journey started, its own readiness probe included. The journey ends NOT VERIFIED, not FAIL, when a service still fails every rerun, an app was killed by SIGKILL, SIGTERM, SIGHUP or SIGINT that the harness did not send, or the app the harness started failed to bind the port the harness gave it (`EADDRINUSE` naming that port). An app that exits on its own with an exit code, one that crashes by another signal such as SIGABRT or SIGSEGV, and one that logs `EADDRINUSE` for any other port are the product's failure. A change that takes its own service down still reads as an outage: the service stays down, so the journey is NOT VERIFIED. For anything else the journey depends on, such as a process it started with `context.command` or an outside endpoint, probe it when a check fails and call `context.notVerified(reason)` when it no longer answers.
  - `context.prepared(key, build)` does the preparation many journeys repeat once per run, such as scaffolding and installing a project, and returns the journey's own copy at `<work>/<key>`. The first journey that asks for `key` runs `build(folder)` on the empty folder with its usual steps, after a step `prepared <key>` that marks them as the build and says whether it was kept. A build is kept until `clean` only when it returns, records at least one check, passes every check, and leaves only files, directories and symlinks in the folder. Every later journey of the run, also in a later `journey` command, gets a fresh copy and one step, `prepared <key>`, that names the journey that built it and holds that build's evidence under `build/`. A build that is not kept is built again by the next journey, and rerunning the journey that built builds again. An absolute symlink into the folder points into each copy; other symlinks keep their target. `build` writes only inside the folder it is given: a write elsewhere, such as a sibling under `<work>` or the repository, stays with the journey that built. Two concurrent `journey` commands that reach the same key at once both build, and the first to finish is kept. The commands `build` runs get a `HOME` of their own that is deleted when it ends: redo after `prepared` anything a later step needs in `HOME`, such as `ajs config set git`. Pass the same `build` for a key in every journey.
  - `env`, `setup` (commands replacing the build), `userFacing` and `shared` (globs replacing the kind's default; `shared` lists the files whose change runs every feature), and `formal` (formal checks: `name`, `covers`, `command`, `violation` with an optional `states` group for the counterexample length, and optionally `behaviour` and `baseCommand`).
- `services`: image, port, readiness command and a `reset` command run before every journey, as for a module. `new` starts them in Docker on free ports; a journey reads them with `context.service(name)` and `context.native(...)`.
- `interface.provide(api, services)` runs in the stub provider after the generic stubs attach, for example to hand a client pointed at `services` to `internal.SetClient`.
- `interface.calls["<entry>:<path>"]` calls a plain exported function from the consumer and states the value it must return.
- `interface.providerSide["<entry>:<path>"]` names a function only providers call, with the reason.
- `features/README.md`: the index of the features; `map` does not read it as a feature.
- `features/<feature>.md`: frontmatter lists `covers:` (source globs), `docs:` (pages a verdict judges) and `journeys:`, then the sections Sub-features, How to get to it (user POV), Driving it with antelopejs-verify, and Gotchas. `features/smoke.md` covers nothing and runs on every verdict; here it runs `every-function`.

```bash
node_modules/.bin/antelopejs-verify map
```

`map` fails on a user-facing file no feature covers, a feature without journeys or docs, an unknown journey, and a `verify.config.ts` journey no feature names.

## Verdict rules

1. **Run every feature whose `covers:` globs the diff touches, plus `smoke`.** `plan` prints that list as `run`. When the diff changes a shared file (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig.json`, `tsconfig.*.json`, `antelope-lock/**`; `shared` in `verify.config.ts` replaces this list; files under `.agents/`, `.claude/` and `.github/` never count), `run` is every feature, every feature's docs pages are judged, and `full` says why. Before a release, create the run with `new --all` and plan with `plan --all`: every feature runs, whatever the diff.
2. **An unmapped surface fails the verdict.** A changed user-facing file no feature covers needs a feature entry and its journeys in the same PR.
3. **Every registered journey of a feature in `run` must have run and passed.** Run whole features. A journey that could not reach the product, or whose environment went away during it, is NOT VERIFIED, and so is the verdict, whatever else passed: never PASS and never PASS+NOTES. Every journey result in the run's evidence counts, also for a feature outside `run`: a failed one fails the verdict, because it shows a `covers:` glob that misses what the diff broke. A NOT VERIFIED one outside `run` is listed under Not verified and caps the result at PASS+NOTES. A journey outside `run` that never ran is not required.
4. **Docs.** Judge every page `plan` lists as `docs` against what the journeys showed: the `docs:` pages of the touched features, or of every feature when the full set runs. A stale page fails the verdict.
5. **Formal checks.** `node_modules/.bin/antelopejs-verify formal <run>` runs every formal check of `verify.config.ts` that covers the diff, or whose own `files` the diff changes, and records it under `evidence/formal/<name>/`. For each one it decides, without judgement, whether the diff changed what the covered code does. `emit` (the default) compares the structure of the covered files' JavaScript on the base and on HEAD: node kinds, names and literal values, leaving out types, comments, formatting, parentheses and `export` keywords. Each use of an imported binding stands for its origin (the resolved module and the imported name), so an import retargeted to another module or alias counts as changed; a function declaration refers to the top-level variables and classes of its own file by file and name, so moving it next to a different variable of the same name counts as changed. Exports are keyed by the origin they export, so a re-export or an `export { f as run }` retargeted to another binding counts as changed. Each file must keep its top-level statements and its side-effect imports in order; function declarations, which are hoisted, may move between covered files with their imports. So a type-only edit, a reformat or a moved function declaration counts as unchanged, while reordering statements or moving any other statement counts as changed. `emit` judges behaviour, not the public surface: exports are the api-diff's job. `probe` runs the check's `behaviour.command` with a worktree of each commit and compares what it prints. Then:
   - a covered check that did not run, or exits non-zero (a tool error, or a check that no longer matches its record), fails the verdict;
   - when the covered behaviour did not change, the verdict reports recorded findings as known findings, except a rule HEAD breaks that the base run did not, which fails the verdict whatever the diff touched, the check's own `files` included; when the base run itself exited non-zero, HEAD's findings cannot be compared and fail the verdict, and so does a result whose check's own `files` changed with no base run recorded. A check the diff adds is the exception: when the base could not run it, the base's `verify.config.ts` never names it, none of its files is a git rename of a base file, and the covered behaviour is unchanged, its recorded findings pass as the record it brings. List those findings in the PR body so a reviewer sees what the record accepts. A new check on a diff that also changes the covered code fails with `new check with a covered-code change: land the check in its own PR first`: land the check alone, then the code change. A moved or renamed check is a changed check;
   - when the covered behaviour changed, or the diff changed the check's own `files`, `formal` also runs the check on the base (`baseCommand` when set). A rule the base broke counts as fixed only when HEAD reports it passing (`passing`); a rule the base broke that HEAD does not report at all fails the verdict. A change that leaves no violated rule passes;
   - when the covered behaviour changed, recorded findings fail the verdict unless the base run exited 0 and broke each of them with the same counterexample length (the `states` named group of `violation`, after the rule's group, in decimal digits; a `states` group that is the first group or captures anything else gives no length), and HEAD fixed every other rule the base broke; then the verdict reports them as the same known findings as the base, with the fixed ones. A new rule, a changed length, or a length either run did not print fails.

   Whether the behaviour changed never reads the check's output, so a model whose rule names stay the same still fails on a changed behaviour unless the rule above keeps its findings known. It is conservative: a local rename or an extracted helper counts as changed, and code outside `covers` is invisible to it. `--all` also runs the checks that do not cover the diff, without gating.
6. **One-way doors.** The section comes right after the result line and is mandatory. `node_modules/.bin/antelopejs-verify doors` prints the `One-way-door:` line of the diff. Every file the path rules flag needs a door row or a false positive with its reason.
7. **Result.** FAIL if any rule fails. NOT VERIFIED when any journey of a required feature is NOT VERIFIED, for example a SaaS module run without its sandbox keys, however many other journeys passed. PASS+NOTES when everything required ran and passed but the judgement lists something no journey reached or something the owner should look at. PASS otherwise.

Write your judgement to `<run>/evidence/judgement.json`:

```json
{
  "doors": {
    "none": "why the diff opens no door",
    "rows": [],
    "falsePositives": [{ "kind": "publish", "location": "package.json", "reason": "only devDependencies changed" }]
  },
  "docs": [{ "page": "README.md", "matches": true, "note": "" }],
  "notVerified": ["What no journey reached, and why"],
  "attention": ["What the owner should look at that the journeys cannot judge"],
  "verifier": "the fresh thread that judged this run, not the author"
}
```

A door row is `{ "kind", "location", "irreversible", "containment" }`, where `containment` says what limits the damage. Then render the verdict:

```bash
node_modules/.bin/antelopejs-verify verdict <run> --pr <n>
```

`verdict` writes `evidence/verdict.md` and exits 1 unless the result is PASS or PASS+NOTES. Report the verdict and what you saw in your own reply, from a thread that did not write the change.

## Trust

The skill is not Trusted yet. It becomes Trusted when it passes a shadow run of 10 consecutive agent PRs and its last maintain pass is newer than the last change to the repository or its `@antelopejs` dependencies and at most 30 days old.

## Gotchas

- A function the consumer awaits forever, such as a getter no provider resolved, fails after 15 seconds with a `Timeout` value.
- `minor-bump` needs the npm registry. Without it the journey is not verified, never passed.
- Runs live under the system temp folder (`TMPDIR`), and the shared caches under `~/.cache/antelopejs-verify`. `new` deletes every run no command touched for 7 days, unless a process it recorded is still alive.
- A repository that outgrows this skill runs `antelopejs-sync --verify custom` and keeps its own `.agents/skills/verify-<repo>/`.
