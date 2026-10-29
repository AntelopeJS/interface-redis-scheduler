---
name: verify-interface
description: "Drive this AntelopeJS interface the way a module author does: pack it, load it in `ajs project dev` next to a stub provider wired through ImplementInterface and a consumer, call every declared function through core, and check the minor-bump rule against the published version. Use to prove a change to the interface works before merge, to verify a PR, or to check that a seeded break is caught."
---

# Verify interface

The user of an interface is a module author: one module implements it, others import it and call its functions through core. Every deterministic step is an `antelopejs-verify` command: you choose which journeys to run and judge what they show. Never replace a command with a shell recipe. When a journey you need does not exist, add it to `verify.config.ts`, name it in its feature file, then run it.

`antelopejs-sync` writes this file and `package.json` here, and keeps them in sync. Everything else in `.agents/skills/verify-interface/` is the repository's own layer, which sync never touches.

## Launch

```bash
pnpm exec antelopejs-verify new --base origin/main --title "<PR title>"
```

`new` prints the run folder; pass it as `<run>` below. `new` runs the setup (`pnpm run build` by default), then packs the interface with `pnpm pack` and extracts it, so journeys load what npm would publish, `files` and `exports` included. Every journey gets its own `HOME` and scratch folder, `CI=1`, `AJS_NO_UPDATE_CHECK=1`, `NO_COLOR=1` and a free port from the kernel, so two runs never share an instance. Run it from the repository root after installing dependencies.

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
  - `doors`: one entry per door kind (`data`, `format`, `contract`, `outbound`, `exposure`, `publish`), each `null` when it cannot apply or `{ globs, funnels, containments, why }`. `containments` names the `feature/journey` that contains a Data or Format door.
  - `journeys`: the repository's journeys by id, each `{ title, entryPoint, run(context) }`, using the check helpers the same import exports.
  - `env`, `setup` (commands replacing the build), `userFacing` (globs replacing the kind's default) and `formal` (formal checks with the files they cover).
- `interface.provide(api)` runs in the stub provider after the generic stubs attach, for example to hand a stub client to `internal.SetClient`.
- `interface.calls["<entry>:<path>"]` calls a plain exported function from the consumer and states the value it must return.
- `interface.providerSide["<entry>:<path>"]` names a function only providers call, with the reason.
- `features/<feature>.md`: frontmatter lists `covers:` (source globs), `docs:` (pages a verdict judges) and `journeys:`, then the sections Sub-features, How to get to it (user POV), Driving it with antelopejs-verify, and Gotchas. `features/smoke.md` covers nothing and runs on every verdict; here it runs `every-function`.
- `seeded-breaks/<feature>.patch`: one minimal product bug per feature that its journeys must catch.
- `seeded-doors/<kind>.patch`: one change per door kind that applies.

```bash
pnpm exec antelopejs-verify map
```

`map` fails on a user-facing file no feature covers, a feature without journeys, docs or seeded break, an unknown journey, an applicable door kind without its seeded door, and a Data or Format door whose `containments` name no journey a feature registers.

## Verdict rules

1. **Run every feature whose `covers:` globs the diff touches, plus `smoke`.** `plan` prints that list as `run`.
2. **An unmapped surface fails the verdict.** A changed user-facing file no feature covers needs a feature entry, its journeys and its seeded break in the same PR.
3. **Every registered journey of a feature in `run` must have run and passed.** Run whole features. A journey that could not reach the product is not verified, and so is the verdict, never PASS.
4. **Docs.** Judge every `docs:` page of a touched feature against what the journeys showed. A stale page fails the verdict.
5. **Formal checks.** `pnpm exec antelopejs-verify formal <run>` runs every formal check of `verify.config.ts` that covers the diff. One that did not run, violates a rule or errors fails the verdict.
6. **One-way doors.** The section comes right after the result line and is mandatory. `pnpm exec antelopejs-verify doors` prints the `One-way-door:` line of the diff. Every file the path rules flag needs a door row or a false positive with its reason. A Data or Format row names a `containments` journey that passed in this run.
7. **Result.** FAIL if any rule fails. NOT VERIFIED when a journey could not reach the product. PASS+NOTES when something is not verified or needs the owner's attention. PASS otherwise.

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

The skill is not Trusted yet. It becomes Trusted when it catches every seeded break and flags every seeded door, passes a shadow run of 10 consecutive agent PRs, and its last maintain pass is newer than the last change to the repository or its `@antelopejs` dependencies and at most 30 days old.

## Seeded breaks and doors

```bash
pnpm exec antelopejs-verify seeded <feature...>
pnpm exec antelopejs-verify seeded-doors
```

`seeded` runs each feature's journeys in a scratch worktree of HEAD without the patch, as the control, and with `seeded-breaks/<feature>.patch` applied. It prints `CAUGHT` only when a journey that passes in the control fails one of its checks with the patch. Journeys failing in the control and failures without a failing check do not count. `seeded-doors` prints `FLAGGED` when the path rules flag each patch with its own kind.

## Gotchas

- A function the consumer awaits forever, such as a getter no provider resolved, fails after 15 seconds with a `Timeout` value.
- `minor-bump` needs the npm registry. Without it the journey is not verified, never passed.
- Runs live under the system temp folder (`TMPDIR`), and the shared caches under `~/.cache/antelopejs-verify`.
- A repository that outgrows this skill runs `antelopejs-sync --verify custom` and keeps its own `.agents/skills/verify-<repo>/`.
