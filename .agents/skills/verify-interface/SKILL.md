---
name: verify-interface
description: "Drive this AntelopeJS interface the way a module author does: pack it, load it in `ajs project dev` next to a stub provider wired through ImplementInterface and a consumer, call every declared function through core, and check the minor-bump rule against the published version. Use to prove a change to the interface works before merge, to verify a PR, or to check that a seeded break is caught."
---

# Verify interface

The user of an interface is a module author: one module implements it, others import it and call its functions through core. Every deterministic step is an `antelopejs-verify` command: you choose which journeys to run and judge what they show. Never replace a command with a shell recipe. When a journey you need does not exist, add it to `verify.config.ts`, name it in its feature file, then run it.

`antelopejs-sync` writes this file, `package.json` and `tsconfig.json` here, and keeps them in sync. Everything else in `.agents/skills/verify-interface/` is the repository's own layer, which sync never touches.

## Launch

```bash
pnpm exec antelopejs-verify new --base origin/main --title "<PR title>"
```

`new` prints the run folder; pass it as `<run>` below. `new` runs the setup (`pnpm run build` by default), then packs the interface with `pnpm pack` and extracts it, so journeys load what npm would publish, `files` and `exports` included. Every `services` entry of `verify.config.ts` then starts in its own Docker container on a free loopback port, as for a module. Every journey gets its own `HOME` and scratch folder, `CI=1`, `AJS_NO_UPDATE_CHECK=1`, `NO_COLOR=1` and a free port from the kernel, so two runs never share an instance. Run it from the repository root after installing dependencies.

## Doctor

```bash
pnpm exec antelopejs-verify doctor <run>
```

Doctor checks that HEAD has not moved since `new`, `ajs` comes from the repository's `@antelopejs/core`, the build is newer than `src/`, what `new` prepared is there, and no process the run recorded is still alive. Do not drive a run that fails doctor.

## Drive

```bash
pnpm exec antelopejs-verify plan --base origin/main
pnpm exec antelopejs-verify journey <run> <feature> [journey...]
```

`plan` maps the diff to features and lists unmapped surfaces. `journey` runs a feature's journeys, or the ones named. The pack ships these journeys for this kind; a feature file names them next to the repository's own:

- `every-function`: a fixture project loads the packed interface with a stub provider and a consumer module. The consumer walks the loaded interface, and every function the `.d.ts` files declare is called through core:
  - an async proxy answers the stub's echo, and the stub's call log shows the same arguments (the second view);
  - a registering proxy registers and unregisters, and the stub logs both;
  - an event proxy delivers the emitted arguments to a registered handler;
  - a plain function runs the `interface.calls` hook of `verify.config.ts` and must return its `expect`; one only providers call is listed in `interface.providerSide` with why.
  A declared function with none of these fails the journey.
- `minor-bump`: reads the declared functions of the packed head and of the published version (`npm pack <name>@<latest>`). An added, changed or removed function needs a release of at least the next minor. The release is the head version when it is already bumped, otherwise what changelogen makes of the change title (`new --title`) or the commit subjects since the base.

## Evidence

Each step writes `<run>/evidence/<feature>/<journey>/<NN-step>/` with `command.txt`, `stdout.txt`, `stderr.txt`, `exit-code.txt`, `pid.txt` for background processes, `tree.txt`, `http.json` for every request, and `checks.json`. `result.json` holds a journey's result and `feature.json` the merged results of the feature. Read the evidence before you judge a PASS: a check proves only what it asserts.

## Cleanup

```bash
pnpm exec antelopejs-verify clean <run>
```

`clean` stops what the run started, by recorded PID and container name, and removes everything but `evidence/` and `run.json`. Run it after every run, failed ones included.

## The repository's own layer

- `verify.config.ts` default-exports a `VerifyConfig` from `@antelopejs/tooling-configs/verify`:
  - `doors`: one entry per door kind (`data`, `format`, `contract`, `outbound`, `exposure`, `publish`), each `null` when it cannot apply or `{ globs, funnels, containments, why }`. `containments` names the `feature/journey` journeys that contain a Data or Format door. Each must fail with that kind's seeded door applied and pass without it: write the journey so one of its checks reads the state the door corrupts.
  - `journeys`: the repository's journeys by id, each `{ title, entryPoint, run(context) }`, using the check helpers the same import exports.
  - `env`, `setup` (commands replacing the build), `userFacing` (globs replacing the kind's default) and `formal` (formal checks: `name`, `covers`, `command`, `violation`, and optionally `behaviour` and `baseCommand`).
- `services`: image, port, readiness command and a `reset` command run before every journey, as for a module. `new` starts them in Docker on free ports; a journey reads them with `context.service(name)` and `context.native(...)`.
- `interface.provide(api, services)` runs in the stub provider after the generic stubs attach, for example to hand a client pointed at `services` to `internal.SetClient`.
- `interface.calls["<entry>:<path>"]` calls a plain exported function from the consumer and states the value it must return.
- `interface.providerSide["<entry>:<path>"]` names a function only providers call, with the reason.
- `features/<feature>.md`: frontmatter lists `covers:` (source globs), `docs:` (pages a verdict judges) and `journeys:`, then the sections Sub-features, How to get to it (user POV), Driving it with antelopejs-verify, and Gotchas. `features/smoke.md` covers nothing and runs on every verdict; here it runs `every-function`.
- `seeded-breaks/<feature>.patch`: one minimal product bug per feature that its journeys must catch.
- `seeded-doors/<kind>.patch`: one change per door kind that applies. A Data or Format door's patch must break what its containment journeys check.

```bash
pnpm exec antelopejs-verify map
```

`map` fails on a user-facing file no feature covers, a feature without journeys, docs or seeded break, an unknown journey, an applicable door kind without its seeded door, and a Data or Format door whose `containments` name no journey a feature registers. `containments` (below) then runs those journeys against the seeded doors.

## Verdict rules

1. **Run every feature whose `covers:` globs the diff touches, plus `smoke`.** `plan` prints that list as `run`.
2. **An unmapped surface fails the verdict.** A changed user-facing file no feature covers needs a feature entry, its journeys and its seeded break in the same PR.
3. **Every registered journey of a feature in `run` must have run and passed.** Run whole features. A journey that could not reach the product is NOT VERIFIED, and so is the verdict, whatever else passed: never PASS and never PASS+NOTES.
4. **Docs.** Judge every `docs:` page of a touched feature against what the journeys showed. A stale page fails the verdict.
5. **Formal checks.** `pnpm exec antelopejs-verify formal <run>` runs every formal check of `verify.config.ts` that covers the diff, or whose own `files` the diff changes, and records it under `evidence/formal/<name>/`. For each one it decides, without judgement, whether the diff changed what the covered code does. `emit` (the default) compares the structure of the covered files' JavaScript on the base and on HEAD: node kinds, names and literal values, leaving out types, comments, formatting, parentheses and `export` keywords. Each use of an imported binding stands for its origin (the resolved module and the imported name), so an import retargeted to another module or alias counts as changed; a function declaration refers to the top-level variables and classes of its own file by file and name, so moving it next to a different variable of the same name counts as changed. Exports are keyed by the origin they export, so a re-export or an `export { f as run }` retargeted to another binding counts as changed. Each file must keep its top-level statements and its side-effect imports in order; function declarations, which are hoisted, may move between covered files with their imports. So a type-only edit, a reformat or a moved function declaration counts as unchanged, while reordering statements or moving any other statement counts as changed. `emit` judges behaviour, not the public surface: exports are the api-diff's job. `probe` runs the check's `behaviour.command` with a worktree of each commit and compares what it prints. Then:
   - a covered check that did not run, or exits non-zero (a tool error, or a check that no longer matches its record), fails the verdict;
   - recorded findings fail the verdict only when the covered behaviour changed; when it did not, the verdict reports them as known findings;
   - when the covered behaviour changed, or the diff changed the check's own `files`, `formal` also runs the check on the base (`baseCommand` when set). A rule the base broke counts as fixed only when HEAD reports it passing (`passing`); a rule the base broke that HEAD does not report at all fails the verdict. A change that leaves no violated rule passes.

   The decision never reads the check's output, so a model whose rule names stay the same still fails on a changed behaviour. It is conservative: a local rename or an extracted helper counts as changed, and code outside `covers` is invisible to it. `--all` also runs the checks that do not cover the diff, without gating.
6. **One-way doors.** The section comes right after the result line and is mandatory. `pnpm exec antelopejs-verify doors` prints the `One-way-door:` line of the diff. Every file the path rules flag needs a door row or a false positive with its reason. A Data or Format row names a `containments` journey that passed in this run, and that journey is proven by `pnpm exec antelopejs-verify containments`: it fails with the kind's seeded door applied. A containment that passes with its door contains nothing, so a Data or Format door without one that fails with its door is not contained.
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

A door row is `{ "kind", "location", "irreversible", "containment", "containmentJourney" }`. Then render and publish:

```bash
pnpm exec antelopejs-verify verdict <run> --pr <n>
pnpm exec antelopejs-verify publish <run> --pr <n>
```

`verdict` writes `evidence/verdict.md` and exits 1 unless the result is PASS or PASS+NOTES. `publish` commits the evidence to the orphan branch `verify-evidence` under `pr-<n>/<sha>/` from a temporary worktree, posts the verdict as a PR comment, sets commit status `verify` on the head SHA (`success` for PASS and PASS+NOTES, `error` for NOT VERIFIED, `failure` for FAIL) and reads it back. It prints the error GitHub answers when the token cannot write statuses. A new push voids the status. Post a verdict only from a thread that did not write the change.

## Trust

The skill is not Trusted yet. It becomes Trusted when it catches every seeded break, flags every seeded door, fails every Data and Format containment with its door, passes a shadow run of 10 consecutive agent PRs, and its last maintain pass is newer than the last change to the repository or its `@antelopejs` dependencies and at most 30 days old.

## Seeded breaks and doors

```bash
pnpm exec antelopejs-verify seeded <feature...>
pnpm exec antelopejs-verify seeded-doors
pnpm exec antelopejs-verify containments
```

`seeded` runs each feature's journeys in a scratch worktree of HEAD without the patch, as the control, and with `seeded-breaks/<feature>.patch` applied. It prints `CAUGHT` only when a journey that passes in the control fails one of its checks with the patch. Journeys failing in the control and failures without a failing check do not count. `seeded-doors` prints `FLAGGED` when the path rules flag each patch with its own kind. `containments` runs every Data and Format containment journey in a scratch worktree of HEAD without the door, as the control, and with `seeded-doors/<kind>.patch` applied. It prints `CONTAINED` only when the journey passes in the control and fails one of its checks with the door. `MISSED` means it passes with its door, `UNPROVEN` that it fails in the control or ends without a failing check, and `NO-DOOR` that the kind has no seeded door; the command exits 1 on anything but `CONTAINED`.

## Gotchas

- A function the consumer awaits forever, such as a getter no provider resolved, fails after 15 seconds with a `Timeout` value.
- `minor-bump` needs the npm registry. Without it the journey is not verified, never passed.
- A containment journey of a Data or Format door must check what that door's seeded patch changes, for example the arguments the stub provider logged. `containments` reports one that still passes with its door as `MISSED`.
- Runs live under the system temp folder (`TMPDIR`), and the shared caches under `~/.cache/antelopejs-verify`.
- A repository that outgrows this skill runs `antelopejs-sync --verify custom` and keeps its own `.agents/skills/verify-<repo>/`.
