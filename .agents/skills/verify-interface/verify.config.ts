import { equal } from "@antelopejs/tooling-configs/verify";
import type { Journey, JourneyContext, VerifyConfig } from "@antelopejs/tooling-configs/verify";

/** The sorted set the scheduler stores its tasks in, as docs/1.introduction.md names it. */
const QUEUE_KEY = "SchedulerUtil.Tasks";

/** A due time far enough away (the year 2100) that no timer fires for it. */
const LATER = 4102444800000;

/** The setup every scenario shares: the packed scheduler, a Redis client handed to interface-redis, and small helpers. */
const SCENARIO_PRELUDE = `
const dist = process.argv[2];
const Redis = require(require.resolve("ioredis", { paths: [dist] }));
const redisInterface = require(require.resolve("@antelopejs/interface-redis", { paths: [dist] }));
const scheduler = require(dist);
const KEY = "${QUEUE_KEY}";
const LATER = ${LATER};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const rejection = async (promise) => { try { await promise; return null; } catch (error) { return error.message; } };
const redis = new Redis(process.argv[3]);
redisInterface.internal.SetClient(redis);
`;

const SCENARIO_TAIL = `
main().then((out) => { console.log(JSON.stringify(out)); return redis.quit(); }).then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });
`;

/** The probe header: `Assert<Same<A, B>>` fails to compile when A and B are not assignable both ways. */
const PROBE_HEADER = `
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
type Assert<T extends true> = T;
`;

/** What a scenario must print, and what Redis itself must hold afterwards (`zrange 0 -1 withscores` through redis-cli). */
interface Scenario {
  title: string;
  body: string;
  printed: string;
  stored: string;
  /** `redis-cli` commands run before the scenario: members written in the shape of the last published release (0.0.9), which the packed head must read. */
  seed?: string[][];
}

const SETTLE_MS = 500;
const READY_POLLS = 40;

/** Starts a disposable Redis in Docker on a free loopback port, hands its URL to `use`, and removes the container whatever happens: the interface kind starts no services of its own. */
async function withRedis(context: JourneyContext, use: (url: string, name: string) => Promise<void>): Promise<void> {
  const name = `${process.env.VERIFY_CONTAINER_PREFIX ?? "verify"}-interface-redis-scheduler-redis-${Date.now().toString(36)}`;
  const started = await context.command("start redis", "docker", ["run", "-d", "--name", name, "-p", "127.0.0.1::6379", "redis:7-alpine"], {
    timeoutMs: 120_000,
  });
  try {
    context.expect(started.folder, [{ name: "redis container started", pass: started.exitCode === 0, detail: started.stderr.slice(-300) }], {
      critical: true,
    });
    let ready = false;
    for (let poll = 0; poll < READY_POLLS && !ready; poll += 1) {
      const ping = await context.command("redis ping", "docker", ["exec", name, "redis-cli", "ping"]);
      ready = ping.stdout.includes("PONG");
      if (!ready) await new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
    }
    const mapped = await context.command("redis port", "docker", ["port", name, "6379/tcp"]);
    const port = /:(\d+)$/m.exec(mapped.stdout)?.[1];
    context.expect(mapped.folder, [{ name: "redis answered PONG on a published port", pass: ready && port !== undefined, detail: mapped.stdout }], {
      critical: true,
    });
    await use(`redis://127.0.0.1:${port}`, name);
  } finally {
    await context.command("remove redis", "docker", ["rm", "-f", name]);
  }
}

/** Runs a scenario against the packed scheduler and a live Redis, then reads the sorted set back through redis-cli: the second view. */
function scenario({ title, body, printed, stored, seed = [] }: Scenario): Journey {
  return {
    title,
    entryPoint: "the packed scheduler driven from a Node process with a Redis client handed to interface-redis",
    async run(context) {
      await withRedis(context, async (url, container) => {
        for (const command of seed) {
          const seeded = await context.command("seed a member the 0.0.9 release wrote", "docker", ["exec", container, "redis-cli", ...command]);
          context.expect(seeded.folder, [equal("redis-cli stored the seeded member", seeded.stdout.trim(), "1")], { critical: true });
        }
        const file = `${context.work}/scenario.js`;
        context.edit("write the scenario", file, `${SCENARIO_PRELUDE}\nasync function main() {\n${body}\n}\n${SCENARIO_TAIL}`);
        const ran = await context.command("run the scenario", "node", [file, `${context.repo}/dist/index.js`, url], { timeoutMs: 60_000 });
        context.expect(ran.folder, [
          { name: "the scenario ended cleanly", pass: ran.exitCode === 0, detail: ran.stderr.slice(-300) },
          equal("the scenario printed what docs/1.introduction.md promises", ran.stdout.trim().split("\n").at(-1) ?? "", printed),
        ]);
        const read = await context.command("read the queue back", "docker", [
          "exec",
          container,
          "redis-cli",
          "zrange",
          QUEUE_KEY,
          "0",
          "-1",
          "withscores",
        ]);
        context.expect(read.folder, [equal("Redis holds the queue the scenario left", read.stdout.trim(), stored)]);
      });
    },
  };
}

/** Compiles a probe against the packed declarations in the consumer's strict mode. */
function declared(title: string, probe: string): Journey {
  return {
    title,
    entryPoint: "a TypeScript consumer compiling against the packed declarations",
    async run(context) {
      const file = `${context.work}/probe.ts`;
      context.edit("write the signature probe", file, `import type * as Api from "${context.repo}/dist/index";\n${PROBE_HEADER}\n${probe}`);
      const compiled = await context.command("compile the signature probe", "node", [
        `${context.repo}/node_modules/typescript/bin/tsc`,
        "--noEmit",
        "--strict",
        "--skipLibCheck",
        "--target",
        "es2022",
        "--module",
        "commonjs",
        "--moduleResolution",
        "node",
        "--typeRoots",
        `${context.repo}/node_modules/@types`,
        "--types",
        "node",
        file,
      ]);
      context.expect(compiled.folder, [
        { name: "every export has the documented signature", pass: compiled.exitCode === 0, detail: compiled.stdout.slice(0, 400) },
      ]);
    },
  };
}

const QUEUE_BODY = `
  scheduler.setHandler("mail", () => {});
  await scheduler.addTask("mail", LATER, "a:b");
  await scheduler.addTask("mail", LATER, "first");
  await scheduler.addTask("mail", LATER + 1000, "second");
  const unknownAdd = await rejection(scheduler.addTask("nobody", LATER, "x"));
  const unknownRemove = await rejection(scheduler.removeTask("nobody", "x"));
  await scheduler.removeTask("mail", "first");
  await scheduler.removeTask("mail", "never-added");
  await scheduler.removeTask("mail", "legacy");
  return { unknownAdd, unknownRemove, members: await redis.zrange(KEY, 0, -1) };
`;

const HANDLERS_BODY = `
  const colon = (() => { try { scheduler.setHandler("a:b", () => {}); return null; } catch (error) { return error.message; } })();
  scheduler.setHandler("fine-name", () => {});
  await scheduler.addTask("fine-name", LATER, "ok");
  return { colon, accepted: await redis.zrange(KEY, 0, -1) };
`;

const DELIVERY_BODY = `
  const received = [];
  scheduler.setHandler("echo", (info) => { received.push(info); });
  await scheduler.addTask("echo", Date.now() - 1000, "p:q:r");
  await scheduler.addTask("echo", LATER, "later");
  await scheduler.runTasks();
  return { received, left: await redis.zrange(KEY, 0, -1) };
`;

const RETRY_BODY = `
  const attempts = [];
  scheduler.setHandler("flaky", (info) => { attempts.push(info); throw new Error("flaky " + info); });
  const beforeLegacy = Date.now();
  await scheduler.runTasks();
  const legacyRows = await redis.zrange(KEY, 0, -1, "WITHSCORES");
  const legacy = [legacyRows[0], Number(legacyRows[1]) - beforeLegacy >= 4000 && Number(legacyRows[1]) - beforeLegacy <= 6500];
  const stage = async (member) => {
    await redis.del(KEY);
    await redis.zadd(KEY, Date.now() - 1000, member);
    const before = Date.now();
    await scheduler.runTasks();
    const rows = await redis.zrange(KEY, 0, -1, "WITHSCORES");
    return rows.length === 0 ? [] : [rows[0], Number(rows[1]) - before >= 4000 && Number(rows[1]) - before <= 6500];
  };
  const first = await stage("flaky:job");
  const second = await stage("RETRY-1:flaky:job");
  const third = await stage("RETRY-2:flaky:job");
  const last = await stage("RETRY-3:flaky:job");
  return { legacy, first, second, third, last, attempts: attempts.length };
`;

const LISTENER_BODY = `
  const fired = [];
  scheduler.setHandler("tick", () => { fired.push(Date.now()); });
  await scheduler.enableListener();
  const started = Date.now();
  await scheduler.addTask("tick", started + 1500, "t");
  await sleep(700);
  const early = fired.length;
  await sleep(2500);
  const late = fired.length;
  await scheduler.disableListener();
  return { early, late, onTime: fired.length === 1 && fired[0] - started >= 1400 && fired[0] - started < 3500, left: await redis.zrange(KEY, 0, -1) };
`;

const SIGNATURES = `
type Handler = (taskInfo: string) => void | Promise<void>;
type _Set = Assert<Same<typeof Api.setHandler, (handlerName: string, handler: Handler) => void>>;
type _Add = Assert<Same<typeof Api.addTask, (handlerName: string, dueTime: number, taskInfo: string) => Promise<void>>>;
type _Remove = Assert<Same<typeof Api.removeTask, (handlerName: string, taskInfo: string) => Promise<void>>>;
type _Enable = Assert<Same<typeof Api.enableListener, () => Promise<void>>>;
type _Disable = Assert<Same<typeof Api.disableListener, () => Promise<void>>>;
type _Update = Assert<Same<typeof Api.updateTimer, () => Promise<void>>>;
type _Run = Assert<Same<typeof Api.runTasks, () => Promise<void>>>;
`;

const config: VerifyConfig = {
  doors: {
    data: null,
    format: {
      globs: ["src/index.ts"],
      funnels: [],
      containments: ["queue/queue-members", "delivery/retry-chain"],
      why: "the sorted set key SchedulerUtil.Tasks, the handlerName:taskInfo and RETRY-n:handlerName:taskInfo members and the pub/sub channel are what queued tasks persist as in Redis",
    },
    contract: {
      globs: ["src/index.ts", "package.json"],
      funnels: [],
      containments: [],
      why: "the seven exports are what every module scheduling work imports",
    },
    outbound: null,
    exposure: null,
    publish: {
      globs: ["package.json", ".release-it.json", "changelogen.config.json", ".github/workflows/release.yml"],
      funnels: [],
      containments: [],
      why: "the package name and release workflow claim @antelopejs/interface-redis-scheduler on npm",
    },
  },
  journeys: {
    "queue-members": scenario({
      title: "addTask and removeTask keep handlerName:taskInfo members in the sorted set",
      body: QUEUE_BODY,
      printed:
        '{"unknownAdd":"Unknown SchedulerUtil handler: nobody","unknownRemove":"Unknown SchedulerUtil handler: nobody","members":["mail:a:b","mail:second","mail:legacy-keep"]}',
      stored: `mail:a:b\n${LATER}\nmail:second\n${LATER + 1000}\nmail:legacy-keep\n${LATER + 3000}`,
      seed: [
        ["zadd", QUEUE_KEY, String(LATER + 2000), "mail:legacy"],
        ["zadd", QUEUE_KEY, String(LATER + 3000), "mail:legacy-keep"],
      ],
    }),
    "handler-names": scenario({
      title: "setHandler refuses a name with a colon and accepts any other",
      body: HANDLERS_BODY,
      printed: '{"colon":"SchedulerUtil handler name may not contain `:`","accepted":["fine-name:ok"]}',
      stored: `fine-name:ok\n${LATER}`,
    }),
    "due-delivery": scenario({
      title: "runTasks hands a due task its payload once and leaves later tasks queued",
      body: DELIVERY_BODY,
      printed: '{"received":["p:q:r"],"left":["echo:later"]}',
      stored: `echo:later\n${LATER}`,
    }),
    "retry-chain": scenario({
      title: "a failing handler is retried as RETRY-1 to RETRY-3 about five seconds later, then dropped",
      body: RETRY_BODY,
      printed:
        '{"legacy":["RETRY-3:flaky:old",true],"first":["RETRY-1:flaky:job",true],"second":["RETRY-2:flaky:job",true],"third":["RETRY-3:flaky:job",true],"last":[],"attempts":5}',
      stored: "",
      seed: [["zadd", QUEUE_KEY, "1000", "RETRY-2:flaky:old"]],
    }),
    "listener-timer": scenario({
      title: "an enabled listener runs a task when it falls due, and not before",
      body: LISTENER_BODY,
      printed: '{"early":0,"late":1,"onTime":true,"left":[]}',
      stored: "",
    }),
    signatures: declared("the seven exports have the documented signatures", SIGNATURES),
  },
};

export default config;
