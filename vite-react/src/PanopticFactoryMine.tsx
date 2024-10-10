import { Address, encodePacked, keccak256, toHex, zeroAddress } from "viem";
import { readContract, simulateContract } from "wagmi/actions";
import { config } from "./wagmi.ts";
import {
  panopticFactoryAbi,
  panopticFactoryAddress,
  panopticPoolAbi,
  panopticPoolAddress,
} from "./generated";
import { useAccount, useReadContract, useSimulateContract } from "wagmi";
import { useCallback, useState } from "react";

type PanopticNFTMetadata = {
  name: string;
  description: string;
  attributes: Array<{
    trait_type: string;
    value: string;
  }>;
  image: string;
};

// TODO: can avoid a static call to simulate pool deployment if minePoolAddress returned the best panopticPoolAddress instead of rarity (instead of best salt and rarity)
// export const minePoolAddress = (
//   deployerAddress: Address,
//   v3Pool: Address,
//   salt: bigint,
//   loops: bigint,
//   minTargetRarity: number,
// ): { bestSalt: number; highestRarity: number } => {
//   let bestSalt = salt;
//   let highestRarity = 0;

//   const maxSalt = salt + loops;

//   for (; salt < maxSalt; ) {
//     const truncatedDeployerAddress = BigInt(deployerAddress) >> 80n;
//     const truncatedV3Pool = BigInt(v3Pool) >> 80n;
//     console.log({ truncatedDeployerAddress, truncatedV3Pool });

//     const newSalt = encodePacked(
//       ["uint80", "uint80", "uint96"],
//       [truncatedDeployerAddress, truncatedV3Pool, salt],
//     );

//     readContract(config, {
//       abi: panopticPoolAbi,
//       address: panopticPoolAddress[11155111],
//       functionName: 'predictDeterministicAddress',
//     })
//     // const rarity = PanopticMath.numberOfLeadingHexZeros(
//     //   POOL_REFERENCE.predictDeterministicAddress(newSalt),
//     // );

//     if (rarity > highestRarity) {
//       highestRarity = rarity;
//       bestSalt = salt;
//     }

//     if (rarity >= minTargetRarity) {
//       highestRarity = rarity;
//       bestSalt = salt;
//       break;
//     }

//     salt += 1;
//   }

//   return { bestSalt, highestRarity };
// };

export const PanopticFactoryMine = () => {
  const { address } = useAccount();
  const v3Pool = "0x9c74625bc3a1f2a60725eee429df10a1758e6382"; // USDT / weth 0.03%
  const generateSalt = useCallback(() => {
    const randomValues = crypto.getRandomValues(new Uint32Array(3));
    // Create a random uint96 by concatenating 3 random uint32s
    const salt =
      (BigInt(randomValues[0]) << 64n) | (BigInt(randomValues[1]) << 32n) | BigInt(randomValues[2]);
    return toHex(salt).toString().slice(2); // `.slice(2)` to remove the leading '0x'
  }, []);
  const [salt, setSalt] = useState(generateSalt);

  const loops = 2n ** 16n;
  const minTargetRarity = 20n;

  // const minePoolAddress = async () => {
  //   let minePoolAddressData;
  //   try {
  //     console.log('mining')
  //     minePoolAddressData = await readContract(config, {
  //       abi: panopticFactoryAbi,
  //       // address: panopticFactoryAddress[11155111],
  //       address: '0xbd3fc358ff62841a951f462eba20bca0428d9706',
  //       functionName: "minePoolAddress",
  //       args: [address ?? zeroAddress, v3Pool ?? zeroAddress, salt, loops, minTargetRarity],
  //     });
  //   } catch (e) {
  //     console.error("Error mining", e);
  //     console.error("Error mining", e.message);
  //     throw e;
  //   }

  //   console.log('minePoolAddressData: ', minePoolAddressData);

  //   // usdt: 0x5f4c7d793d898e64eddd1fc82d27ecfb5f6e4596
  //   const token0 = "0x5f4c7d793d898e64eddd1fc82d27ecfb5f6e4596"; // address
  //   // weth: 0xfff9976782d46cc05630d1f6ebab18b2324d6b14
  //   const token1 = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"; // address
  //   const fee = 3000; // uint24
  //   // salt      // uint96
  //   const amount0Max = 2n ** 256n - 1n; // uint256 - ignore slippage for testing
  //   const amount1Max = 2n ** 256n - 1n; // uint256 - ignore slippage for testing
  //   try {

  //   const simulateDeployData = await simulateContract(config, {
  //     abi: panopticFactoryAbi,
  //     // address: panopticFactoryAddress[11155111],
  //     address: '0xbd3fc358ff62841a951f462eba20bca0428d9706',
  //     functionName: "deployNewPool",
  //     args: [token0, token1, fee, salt, amount0Max, amount1Max],
  //   });
  //   console.log(simulateDeployData);
  //   } catch(e){
  //     console.error('Dep err: ', e)
  //     console.error('Dep err: ', e.message)
  //   }
  // };

  const { data: minePoolAddressData } = useReadContract({
    abi: panopticFactoryAbi,
    // address: panopticFactoryAddress[11155111],
    address: "0xbd3fc358ff62841a951f462eba20bca0428d9706",
    functionName: "minePoolAddress",
    args: [address ?? zeroAddress, v3Pool ?? zeroAddress, BigInt(salt), loops, minTargetRarity],
  });

  // usdt: 0x5f4c7d793d898e64eddd1fc82d27ecfb5f6e4596
  const token0 = "0x5f4c7d793d898e64eddd1fc82d27ecfb5f6e4596"; // address
  // weth: 0xfff9976782d46cc05630d1f6ebab18b2324d6b14
  const token1 = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"; // address
  const fee = 3000; // uint24
  // salt      // uint96
  const amount0Max = 2n ** 256n - 1n; // uint256 - ignore slippage for testing
  const amount1Max = 2n ** 256n - 1n; // uint256 - ignore slippage for testing
  const { data: simulateDeployNewPoolData } = useSimulateContract({
    abi: panopticFactoryAbi,
    // address: panopticFactoryAddress[11155111],
    address: "0xbd3fc358ff62841a951f462eba20bca0428d9706",
    functionName: "deployNewPool",
    args: [token0, token1, fee, BigInt(salt), amount0Max, amount1Max],
  });

  const { data: tokenUriData } = useReadContract({
    abi: panopticFactoryAbi,
    // address: panopticFactoryAddress[11155111],
    address: "0xbd3fc358ff62841a951f462eba20bca0428d9706",
    functionName: "tokenURI",
    // test
    args: [BigInt("0x00c34C41289e6c433723542BB1Eba79c6919504EDD")],
    // prod
    // args: [BigInt(simulateDeployNewPoolData?.result ?? zeroAddress)],
    // query:{
    //   enabled: simulateDeployNewPoolData?.result != null && simulateDeployNewPoolData?.result !== zeroAddress,
    // }
  });

  console.log("tokenUriData: ", tokenUriData);

  const tokenUriAtob =
    tokenUriData !== undefined
      ? atob(tokenUriData.split("data:application/json;base64,")[1])
      : undefined;
  console.log("tokenUriAtob: ", tokenUriAtob);

  const parsedTokenUri: PanopticNFTMetadata =
    tokenUriAtob !== undefined ? JSON.parse(tokenUriAtob) : undefined;
  console.log("parsedTokenUri", parsedTokenUri);

  const name = parsedTokenUri.name;
  const svgString = parsedTokenUri.image;

  return (
    <div>
      <h3>Panoptic NFT Mine</h3>
      <button onMouseDown={generateSalt}>Mine</button>
      <div className="hover:cursor-pointer hover:opacity-75 active:scale-[0.99] relative w-fit">
        <img alt={name} src={svgString} className="h-96 w-fit" />
      </div>
    </div>
  );
};
