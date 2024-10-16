// SPDX-License-Identifier: MIT

// What are our invariants?

//1. The total supply of DSC should be less than the total value of collateral
//2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    ERC20Mock weth;
    ERC20Mock wbtc;
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address[] tokenAddresses;
    address[] priceFeedAddresses;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dscEngine, dsc, helperConfig) = deployer.run();
        (tokenAddresses, priceFeedAddresses,) = helperConfig.getFullNetworkConfig();
        weth = ERC20Mock(tokenAddresses[0]);
        wbtc = ERC20Mock(tokenAddresses[1]);
        // targetContract(address(dscEngine));
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of the collateral in the protocol
        // compare it to all the debt in the protocol
        uint256 totalSupply = dsc.totalSupply();

        uint256 wethDepositInUsd = dscEngine.getUsdValue(address(weth), weth.balanceOf(address(dscEngine)));
        uint256 wbtcDepositInUsd = dscEngine.getUsdValue(address(wbtc), wbtc.balanceOf(address(dscEngine)));
        uint256 totalCollateralValue = wethDepositInUsd + wbtcDepositInUsd;

        // if (totalSupply > 0) {
        console.log("Total Supply: ", totalSupply);
        console.log("Total Weth in USD: ", wethDepositInUsd);
        console.log("Total Wbtc in USD: ", wbtcDepositInUsd);
        console.log("Total Collateral Value: ", totalCollateralValue);

        // }

        assert(totalCollateralValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        // Existing calls from DecentralizedStableCoin contract
        dsc.totalSupply();
        dsc.balanceOf(address(this));
        dsc.allowance(address(this), address(this));

        // DSCEngine contract getters
        dscEngine.getHealthFactor(address(this));
        dscEngine.getAccountInformation(address(this));
        dscEngine.getUsersTokenCollateralDeposited(address(this), address(weth));
        dscEngine.getUsersTotalTokenCollateralDeposited(address(this));
        dscEngine.getMinHealthFactor();
        dscEngine.getLiquidationThreshold();
        dscEngine.getLiquidationPrecision();
        dscEngine.getLiquidationBonus();
        dscEngine.getPriceFeed(address(weth));
        dscEngine.getCollateralTokens();

        // Also ensuring no reverts when fetching USD value and collateral value in USD
        dscEngine.getUsdValue(address(weth), 1 ether);
        dscEngine.getAccountCollateralValueInUsd(address(this));

        // This can include more specific tests or checks for functions requiring arguments
        // For instance, simulating different scenarios for getTokenAmountFromUsd
        dscEngine.getTokenAmountFromUsd(address(weth), 1000 ether);
    }
}
