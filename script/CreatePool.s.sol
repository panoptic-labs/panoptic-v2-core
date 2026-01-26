import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactoryV4.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract CreatePool is Script {
    function run() public {
        PanopticFactory factory = PanopticFactory(vm.envAddress("PANOPTIC_FACTORY_V4"));
        IRiskEngine riskEngine = IRiskEngine(vm.envAddress("RISK_ENGINE"));

        address currency0 = vm.envAddress("CURRENCY0");
        address currency1 = vm.envAddress("CURRENCY1");
        uint24 fee = uint24(vm.envUint("FEE"));
        int24 tickSpacing = int24(uint24(vm.envUint("TICK_SPACING")));

        PoolKey memory key = PoolKey(
            Currency.wrap(currency0),
            Currency.wrap(currency1),
            fee,
            tickSpacing,
            IHooks(address(0))
        );

        console.log("Creating Panoptic Pool (V4)");
        console.log("Currency0:", currency0);
        console.log("Currency1:", currency1);
        console.log("Fee:", fee);
        console.log("Tick Spacing:", uint256(uint24(tickSpacing)));
        console.log("Factory:", address(factory));
        console.log("RiskEngine:", address(riskEngine));

        vm.startBroadcast();

        uint96 salt = 0;
        PanopticPool newPool = factory.deployNewPool(key, riskEngine, salt);

        console.log("Successfully deployed Panoptic Pool at:", address(newPool));

        vm.stopBroadcast();
    }
}
