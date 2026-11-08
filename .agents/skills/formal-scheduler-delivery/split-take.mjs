#!/usr/bin/env node
/**
 * Model-checks SplitTake.cfg: the Claim bounds with the take runTasks used
 * before #26, ZRANGEBYSCORE then ZREM of the members it read
 * (`TakeScript = FALSE`). Each rule the one-script take keeps must break
 * here with its recorded counterexample length, so a model edit that stops
 * the claim rules from catching a revert of #26 exits 1. check.mjs runs this
 * script and prefixes its lines, so a reader of check.mjs output never takes
 * these expected breaks for findings about src/index.ts.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkSpec } from "@antelopejs/tooling-configs/formal";

await checkSpec({
  dir: path.dirname(fileURLToPath(import.meta.url)),
  spec: "SchedulerDelivery",
  config: "SplitTake",
  findings: { HandOffOnce: 10, NoDroppedTask: 8, AttemptsBounded: 10 },
});
