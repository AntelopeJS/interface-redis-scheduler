import { antelopeKnipConfig } from "@antelopejs/tooling-configs/knip";

export default antelopeKnipConfig({
  entry: [
    // `ajs module test` runs the compiled suites out of this tree, and reads
    // src/antelope.test.ts (package.json antelopeJs.test) to build the test
    // project; the preset only knows the `src/test/` spelling. The compiled
    // tree ships in the package, and the modules implementing this interface
    // run it as their conformance suite.
    "src/tests/**/*.test.ts",
    "src/antelope.test.ts",
  ],
  // `ajs` comes from @antelopejs/core, which CI installs globally rather than
  // pulling the whole CLI into every module's dependency tree.
  ignoreBinaries: ["ajs"],
});
