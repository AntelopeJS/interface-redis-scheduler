import { defineConfig } from "@antelopejs/interface-core/config";

export default defineConfig({
  name: "interface-redis-scheduler-test",
  cacheFolder: ".antelope/cache",
  modules: {
    redis: {
      source: {
        type: "package",
        package: "@antelopejs/redis",
        version: "1.0.1",
      },
      config: { useMock: true },
    },
  },
  test: {
    folder: "dist/tests",
  },
});
