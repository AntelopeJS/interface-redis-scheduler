/**
 * Reader's view of SchedulerDelivery.tla for /statechart: one region for the
 * queue in Redis, one per listener and one for the app.
 */

/**
 * A listener's continuation: `k` names what it waits on, and `m` is the
 * member `<<task, retry>>` it is about, a tuple keyed from 1.
 * @typedef {{ k: string, m: Record<string, number> }} Cont
 */

/**
 * The variables of SchedulerDelivery.tla this view reads, as /statechart
 * passes them: a sequence is an object keyed from 1, a set is an array, and
 * a function of tuples is keyed by each tuple's JSON.
 * @typedef {object} Vars
 * @property {number} now
 * @property {Record<string, number>} zset
 * @property {{ op: string }[]} cops
 * @property {Record<string, boolean>} locked
 * @property {Record<string, number>} timer
 * @property {Record<string, Record<string, Cont>>} fifo
 * @property {Record<string, Record<string, Cont>>} busy
 */

/** @param {Vars} v */
function queue(v) {
  const scores = Object.values(v.zset);
  if (scores.length === 0) return "Empty";
  const due = scores.filter((score) => score <= v.now).length;
  const waiting = scores.length - due;
  return [due > 0 && `${due} due`, waiting > 0 && `${waiting} waiting`].filter(Boolean).join(", ");
}

/**
 * @param {Vars} v
 * @param {string} l
 */
function listener(v, l) {
  const busy = Object.keys(v.busy[l]).length;
  if (busy > 1) return `Running ${busy} handlers at once`;
  if (busy === 1) return "Running a handler";
  const kinds = Object.values(v.fifo[l]).map((c) => c.k);
  if (kinds.some((k) => k === "take" || k === "retry")) return "Taking due tasks";
  if (kinds.length > 0) return "Refreshing the timer";
  return v.timer[l] >= 0 ? "Waiting, timer armed" : "Waiting, no timer";
}

/** @param {Vars} v */
function app(v) {
  const ops = v.cops.map((c) => c.op);
  if (ops.includes("zrem")) return "Calling removeTask";
  if (ops.includes("zadd") || ops.includes("publish")) return "Calling addTask";
  return "Idle";
}

/**
 * One region for the queue, one per listener, one for the app.
 * @param {Vars} v
 * @returns {Record<string, string>}
 */
export function state(v) {
  /** @type {Record<string, string>} */
  const regions = { Queue: queue(v) };
  for (const l of Object.keys(v.locked)) regions[`Listener ${l}`] = listener(v, l);
  regions.App = app(v);
  return regions;
}

const STEPS = new Map([
  ["AddTaskCall", "the app calls addTask"],
  ["AddTaskZadd", "Redis stores the task"],
  ["Publish", "Redis publishes update"],
  ["NotifyUpdate", "the listener gets update"],
  ["RemoveTaskCall", "the app calls removeTask"],
  ["RemoveTaskZrem", "Redis deletes the task"],
  ["ZrangeReply", "Redis names the first task"],
  ["TimerFires", "the timer fires"],
  ["TakeReply", "Redis hands over the due tasks"],
  ["RetryZaddReply", "Redis stores the retry"],
  ["HandlerReturns", "a handler returns"],
  ["HandlerThrows", "a handler throws"],
  ["Tick", "time passes"],
]);

/**
 * @param {Record<string, Cont>} sequence
 * @returns {Cont | undefined}
 */
const first = (sequence) => sequence["1"];

/**
 * @param {Vars} from
 * @param {Vars} to
 */
function scoreStep(from, to) {
  const answered = Object.keys(from.fifo)
    .map((id) => ({ before: first(from.fifo[id]), changed: JSON.stringify(from.fifo[id]) !== JSON.stringify(to.fifo[id]) }))
    .find(({ before, changed }) => changed && before?.k === "zscore")?.before;
  if (answered === undefined) return "Redis answers a score";
  const key = JSON.stringify(answered.m);
  if (!Object.hasOwn(from.zset, key)) return "Redis answers no score: the task is gone";
  return from.zset[key] < from.now
    ? "Redis answers its score: due, a batch starts"
    : "Redis answers its score: not due, the timer is set";
}

/**
 * The arrow label of one TLC step, in what the reader sees happen; `Settled` changes nothing and is hidden.
 * @param {string} action
 * @param {Vars} from
 * @param {Vars} to
 */
export function step(action, from, to) {
  if (action === "Settled") return null;
  return action === "ZscoreReply" ? scoreStep(from, to) : (STEPS.get(action) ?? null);
}

export const title = "Task delivery of interface-redis-scheduler";
