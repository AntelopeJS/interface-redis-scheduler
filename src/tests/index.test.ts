import { expect } from "chai";
import { GetClient } from "@antelopejs/interface-redis";
import {
  addTask,
  disableListener,
  enableListener,
  removeTask,
  runTasks,
  setHandler,
  updateTimer,
} from "../index";

const RedisKey = "SchedulerUtil.Tasks";

async function cleanupRedis() {
  const client = await GetClient();
  await client.del(RedisKey);
}

describe("Redis Scheduler - setHandler", () => {
  it("should register a handler", async () => {
    let called = false;
    setHandler("test-register", () => {
      called = true;
    });
    expect(called).to.equal(false);
  });
  it("should reject handler names containing :", async () => {
    expect(() => setHandler("invalid:name", () => {})).to.throw(
      "may not contain",
    );
  });
});

describe("Redis Scheduler - addTask", () => {
  it("should add a task to the sorted set", async () => {
    await cleanupRedis();
    setHandler("test-add", () => {});

    const dueTime = Date.now() + 60000;
    await addTask("test-add", dueTime, "task-data");

    const client = await GetClient();
    const members = await client.zrange(RedisKey, 0, -1);
    expect(members).to.include("test-add:task-data");

    await cleanupRedis();
  });
  it("should throw for unknown handler", async () => {
    expect(
      await rejectionMessage(
        addTask("nonexistent-handler", Date.now(), "data"),
      ),
    ).to.include("Unknown SchedulerUtil handler");
  });
});

describe("Redis Scheduler - removeTask", () => {
  it("should remove a task from the sorted set", async () => {
    await cleanupRedis();
    setHandler("test-remove", () => {});

    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() + 60000, "test-remove:remove-data");

    await removeTask("test-remove", "remove-data");

    const members = await client.zrange(RedisKey, 0, -1);
    expect(members).to.not.include("test-remove:remove-data");

    await cleanupRedis();
  });
  it("should throw for unknown handler", async () => {
    expect(
      await rejectionMessage(removeTask("nonexistent-handler", "data")),
    ).to.include("Unknown SchedulerUtil handler");
  });
});

describe("Redis Scheduler - enableListener / disableListener", () => {
  it("should enable and disable the listener", async () => {
    await cleanupRedis();
    const executed = new Promise<string>((resolve) => {
      setHandler("test-listener", resolve);
    });

    await enableListener();
    try {
      await addTask("test-listener", Date.now() - 1000, "notified");
      expect(await executed).to.equal("notified");
    } finally {
      await disableListener();
    }

    await cleanupRedis();
  });
  it("should use lazyConnect when duplicating client", async () => {
    const client = await GetClient();
    const originalDuplicate = client.duplicate.bind(client);
    let duplicateOptions: Parameters<typeof client.duplicate>[0];

    client.duplicate = (override) => {
      duplicateOptions = override;
      return originalDuplicate(override);
    };

    try {
      await enableListener();
      expect(duplicateOptions).to.deep.include({ lazyConnect: true });
      await disableListener();
    } finally {
      client.duplicate = originalDuplicate;
    }
  });
});

describe("Redis Scheduler - runTasks", () => {
  it("should execute due tasks", async () => {
    await cleanupRedis();
    const results: string[] = [];
    setHandler("test-run", (taskInfo: string) => {
      results.push(taskInfo);
    });

    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() - 1000, "test-run:payload1");
    await client.zadd(RedisKey, Date.now() - 500, "test-run:payload2");

    await runTasks();

    expect(results).to.include("payload1");
    expect(results).to.include("payload2");

    const remaining = await client.zrange(RedisKey, 0, -1);
    expect(remaining).to.have.length(0);

    await cleanupRedis();
  });
  it("should not execute future tasks", async () => {
    await cleanupRedis();
    const results: string[] = [];
    setHandler("test-future", (taskInfo: string) => {
      results.push(taskInfo);
    });

    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() + 60000, "test-future:future-data");

    await runTasks();

    expect(results).to.have.length(0);

    const remaining = await client.zrange(RedisKey, 0, -1);
    expect(remaining).to.have.length(1);

    await cleanupRedis();
  });
  it("should keep a task rescheduled while due tasks are collected", async () => {
    await cleanupRedis();
    const results: string[] = [];
    setHandler("test-reschedule", (taskInfo: string) => {
      results.push(taskInfo);
    });

    const client = await GetClient();
    const later = Date.now() + 60000;
    await client.zadd(RedisKey, Date.now() - 1000, "test-reschedule:renewal");

    await Promise.all([
      runTasks(),
      addTask("test-reschedule", later, "renewal"),
    ]);

    expect(results).to.deep.equal(["renewal"]);
    expect(await client.zscore(RedisKey, "test-reschedule:renewal")).to.equal(
      String(later),
    );

    await cleanupRedis();
  });
  it("should keep due tasks when reading them fails", async () => {
    await cleanupRedis();
    const results: string[] = [];
    setHandler("test-read-failure", (taskInfo: string) => {
      results.push(taskInfo);
    });

    const client = await GetClient();
    const due = Date.now() - 1000;
    await client.zadd(RedisKey, due, "test-read-failure:renewal");
    if (!isMockClient(client))
      throw new Error("The test project must use the Redis mock");
    const mock = client;
    const store = mock.data;
    let failed = false;
    const failFirstRead = (key: string) => {
      if (!failed && key === RedisKey) {
        failed = true;
        throw new Error("ERR injected read failure");
      }
    };
    mock.data = {
      ...store,
      get: (key) => (failFirstRead(key), store.get(key)),
      has: (key) => (failFirstRead(key), store.has(key)),
    };

    let rejected = false;
    try {
      await runTasks();
    } catch {
      rejected = true;
    } finally {
      mock.data = store;
    }

    expect(failed).to.equal(true);
    expect(rejected).to.equal(true);
    expect(results).to.deep.equal([]);
    expect(await client.zscore(RedisKey, "test-read-failure:renewal")).to.equal(
      String(due),
    );

    await cleanupRedis();
  });
});

interface MockStore {
  get(key: string): ReadonlyMap<string, string> | undefined;
  has(key: string): boolean;
}

function isMockClient<T extends object>(
  client: T,
): client is T & { data: MockStore } {
  if (!("data" in client)) {
    return false;
  }
  const { data } = client;
  return (
    typeof data === "object" &&
    data !== null &&
    "get" in data &&
    typeof data.get === "function" &&
    "has" in data &&
    typeof data.has === "function"
  );
}

describe("Redis Scheduler - timer", () => {
  it("should not keep the process alive while waiting for the next task", async () => {
    await cleanupRedis();
    const fired = new Promise<void>((resolve) => {
      setHandler("test-timer-handle", () => resolve());
    });
    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() + 50, "test-timer-handle:soon");
    await runTasks();
    await fired;

    const timeoutsBefore = liveTimeouts();
    await client.zadd(RedisKey, Date.now() + 60_000, "test-timer-handle:later");
    await updateTimer();
    expect(liveTimeouts()).to.equal(timeoutsBefore);

    await cleanupRedis();
  });
  it("should still run the next task when the first is removed while the timer refreshes", async () => {
    await cleanupRedis();
    const ran = new Promise<string>((resolve) => {
      setHandler("test-remove-race", resolve);
    });
    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() + 50, "test-remove-race:first");
    await client.zadd(RedisKey, Date.now() + 100, "test-remove-race:second");

    const zrange = client.zrange.bind(client);
    let removed = false;
    Object.assign(client, {
      zrange: async (
        key: string,
        start: number,
        stop: number,
        withScores?: "WITHSCORES",
      ) => {
        const reply = withScores
          ? await zrange(key, start, stop, withScores)
          : await zrange(key, start, stop);
        if (!removed && key === RedisKey) {
          removed = true;
          await removeTask("test-remove-race", "first");
        }
        return reply;
      },
    });
    try {
      await updateTimer();
    } finally {
      Object.assign(client, { zrange });
    }

    expect(removed).to.equal(true);
    expect(await withinMs(ran, 1000)).to.equal("second");

    await cleanupRedis();
  });
});

async function withinMs<T>(
  promise: Promise<T>,
  ms: number,
): Promise<T | "timed out"> {
  let timeout: NodeJS.Timeout | undefined;
  const expired = new Promise<"timed out">((resolve) => {
    timeout = setTimeout(() => resolve("timed out"), ms);
  });
  try {
    return await Promise.race([promise, expired]);
  } finally {
    clearTimeout(timeout);
  }
}

describe("Redis Scheduler - retry logic", () => {
  it("should retry failed tasks up to 3 times", async () => {
    await cleanupRedis();
    let callCount = 0;
    setHandler("test-retry", () => {
      callCount++;
      throw new Error("intentional failure");
    });

    const client = await GetClient();
    await client.zadd(RedisKey, Date.now() - 1000, "test-retry:retry-data");

    await runTasks();
    expect(callCount).to.equal(1);

    const retryMembers = await client.zrange(RedisKey, 0, -1);
    expect(retryMembers).to.have.length(1);
    expect(retryMembers[0]).to.match(/^RETRY-1:test-retry:retry-data$/);

    await cleanupRedis();
  });
});

async function rejectionMessage(
  promise: Promise<unknown>,
): Promise<string | undefined> {
  try {
    await promise;
  } catch (err) {
    return err instanceof Error ? err.message : undefined;
  }
  return undefined;
}

function liveTimeouts(): number {
  return process
    .getActiveResourcesInfo()
    .filter((resource) => resource === "Timeout").length;
}
