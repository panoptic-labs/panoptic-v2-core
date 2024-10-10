// @ts-check
import { react } from "@wagmi/cli/plugins";
import { foundry } from "@wagmi/cli/plugins";
import { Address } from "viem";

const deployments: Record<string, Record<number, Address>> = {
  PanopticFactory: {
    11155111: "0xD958AE206C2243CbcC579e11937937E2C71D127F",
  },
  PanopticPool: {
    11155111: "0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08",
  },
};

/** @type {import('@wagmi/cli').Config} */
export default {
  out: "vite-react/src/generated.ts",
  contracts: [],
  // deployments,
  plugins: [
    react(),
    foundry({
      project: "./",
      exclude: [
        // the following patterns are excluded by default
        // 'Common.sol/**',
        // 'Components.sol/**',
        // 'Script.sol/**',
        // 'StdAssertions.sol/**',
        // 'StdInvariant.sol/**',
        // 'StdError.sol/**',
        // 'StdCheats.sol/**',
        // 'StdMath.sol/**',
        // 'StdJson.sol/**',
        // 'StdStorage.sol/**',
        // 'StdUtils.sol/**',
        // 'Vm.sol/**',
        // 'console.sol/**',
        // 'console2.sol/**',
        // 'test.sol/**',
        // '**.s.sol/*.json',
        // '**.t.sol/*.json',
        "**.sol/*",
      ],
      include: ["PanopticFactory.sol/**", "PanopticPool.sol/**"],
      deployments,
    }),
  ],
};
