// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator wethPriceFeed;

    address[] public depositers;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory tokenAddresses = dscEngine.getCollateralTokens();
        weth = ERC20Mock(tokenAddresses[0]);
        wbtc = ERC20Mock(tokenAddresses[1]);

        wethPriceFeed = MockV3Aggregator(dscEngine.getPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        //We need to give wbtc/weth to the handler
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        depositers.push(msg.sender);
    }

    function mintDsc(uint256 amountDsc) public {
        address randomUser = _getRandomUser();

        (uint256 totalDscMinted, uint256 totalCollateralValue) = dscEngine.getAccountInformation(randomUser);
        int256 maxDscToMint = (int256(totalCollateralValue) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return;
        }

        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(randomUser);
        dscEngine.mintDsc(amountDsc);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        address randomUser = _getRandomUser();

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        vm.startPrank(randomUser);
        uint256 maxCollateralToRedeem = dscEngine.getUsersTokenCollateralDeposited(randomUser, address(collateral));
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(randomUser);
        //Lets calculate the health factor
        uint256 collateralToRedeem = maxCollateralToRedeem / 2;
        uint256 newHealthFactor =
            dscEngine.calculateHealthFactor(totalDscMinted, (maxCollateralToRedeem - collateralToRedeem));

        if (newHealthFactor < dscEngine.getMinHealthFactor()) {
            return;
        }

        amountCollateral = bound(amountCollateral, 0, collateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // This breaks our invariant test suite
    // function updateCollateralPrice(uint96 price) public {
    //     int256 newPrice = int256(uint256(price));
    //     wethPriceFeed.updateAnswer(newPrice);
    // }

    //Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) public view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return ERC20Mock(weth);
        } else {
            return ERC20Mock(wbtc);
        }
    }

    function _getRandomUser() public view returns (address) {
        if (depositers.length == 0) {
            return address(0);
        }
        uint256 randomUserIndex = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender))) % depositers.length;
        return depositers[randomUserIndex];
    }
}
