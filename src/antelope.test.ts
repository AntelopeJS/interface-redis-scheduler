import { defineConfig } from "@antelopejs/interface-core/config";

export default defineConfig({
  name: "interface-redis-scheduler-test",
  cacheFolder: ".antelope/cache",
  modules: {
    redis: {
      source: {
        type: "local",
        path: "../redis",
        installCommand: ["pnpm install", "npx tsc"],
      },
      config: { useMock: true },
    },
  },
  test: {
    folder: "dist/tests",
  },
});
