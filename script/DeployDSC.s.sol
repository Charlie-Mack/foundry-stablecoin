// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    DSCEngine private dscEngine;
    DecentralizedStableCoin private dsc;
    HelperConfig private helperConfig;

    function run() external returns (DSCEngine, DecentralizedStableCoin, HelperConfig) {
        helperConfig = new HelperConfig();
        (address[] memory tokenAddresses, address[] memory priceFeedAddresses, uint256 deployerKey) =
            helperConfig.getFullNetworkConfig();
        vm.startBroadcast(deployerKey);
        dsc = new DecentralizedStableCoin();
        dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        dsc.transferOwnership(address(dscEngine));
        vm.stopBroadcast();

        return (dscEngine, dsc, helperConfig);
    }
}
