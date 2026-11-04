#!/usr/bin/env node
/**
 * Model-checks task delivery of @antelopejs/interface-redis-scheduler with
 * TLC through the shared runner of @antelopejs/tooling-configs:
 * SchedulerDelivery.tla with one listener, then with two.
 *
 * With no argument it runs the CI configuration of each (`<config>.ci.cfg`);
 * with `--full` it runs the full one (`<config>.cfg`). Exits 0 when both
 * match the record in SKILL.md, 1 when a rule changed, and 2 when TLC could
 * not run. The runner exits on the first configuration that changed, so a
 * change with one listener skips the two-listener run.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkSpec, EXIT } from "@antelopejs/tooling-configs/formal";

const dir = path.dirname(fileURLToPath(import.meta.url));

/** The findings of each configuration, with the states in TLC's shortest counterexample, in run order. */
const CONFIGS = {
  SchedulerDelivery: {
    ci: { NoOverlapOnInstance: 14, NoLostTask: 7 },
    full: { NoOverlapOnInstance: 14, NoLostTask: 8 },
  },
  TwoListeners: {
    ci: {},
    full: { NoOverlapOnInstance: 16, NoLostTask: 25 },
  },
};

const args = process.argv.slice(2);
if (args.some((arg) => arg !== "--full")) {
  console.error("usage: node check.mjs [--full]");
  process.exit(EXIT.tool);
}
const mode = args.includes("--full") ? "full" : "ci";

for (const [config, findings] of Object.entries(CONFIGS)) {
  await checkSpec({
    dir,
    spec: "SchedulerDelivery",
    config: mode === "full" ? config : `${config}.ci`,
    findings: findings[mode],
  });
}
