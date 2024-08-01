pragma solidity ^0.8.12;

import {FeesCalc} from "@libraries/FeesCalc.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";

contract LibraryDeployer {
    address public feesCalc;
    address public panopticMath;
    address public interactionHelper;

    event LogAddress(string name, address addr);

    constructor() {
        bytes memory code = type(FeesCalc).creationCode;

        address _pointer;
        assembly ("memory-safe") {
            _pointer := create(0, add(code, 0x20), mload(code))
        }
        feesCalc = _pointer;

        code = type(PanopticMath).creationCode;
        assembly ("memory-safe") {
            _pointer := create(0, add(code, 0x20), mload(code))
        }
        panopticMath = _pointer;

        code = type(InteractionHelper).creationCode;
        assembly ("memory-safe") {
            _pointer := create(0, add(code, 0x20), mload(code))
        }
        interactionHelper = _pointer;
    }

    function get_lib_addresses() external {
        emit LogAddress("FeesCalc", feesCalc);
        emit LogAddress("PanopticMath", panopticMath);
        emit LogAddress("InteractionHelper", interactionHelper);

        assert(false);
    }
}
