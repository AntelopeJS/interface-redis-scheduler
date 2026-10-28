import { antelopeKnipConfig } from "@antelopejs/tooling-configs/knip";

export default antelopeKnipConfig({
  entry: ["src/tests/**/*.test.ts", "src/antelope.test.ts"],
});
