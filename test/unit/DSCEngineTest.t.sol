//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mock/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mock/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mock/MockFailedTransfer.sol";

contract DSCEngineTest is Test {
    /* Events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    ERC20Mock weth;
    ERC20Mock wbtc;
    AggregatorV3Interface ethPriceFeed;
    AggregatorV3Interface btcPriceFeed;
    DSCEngine dscEngine;
    DSCEngine dscEngineDebt;
    MockMoreDebtDSC dscDebt;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address[] tokenAddresses;
    address[] priceFeedAddresses;
    address BOB = makeAddr("bob");
    address ALICE = makeAddr("alice");
    int256 ETH_PRICE_CRASH = 3500e8;
    uint256 STARTING_BALANCE = 1000 ether;
    uint256 AMOUNT_COLLATERAL = 10 ether;
    uint256 AMOUNT_COLLATERAL_SUPER_OVER = 100 ether;
    uint256 AMOUNT_COLLATERAL_USD = 40000 ether;
    uint256 DSC_DEBT_TO_COVER = 10000 ether;
    uint256 DSC_MINTED = 20000 ether;
    uint256 TINY_NUMBER = 1;
    uint256 ZERO = 0;

    function setUp() external {
        console.log("Deploying contracts...");
        DeployDSC deployDSC = new DeployDSC();
        (dscEngine, dsc, helperConfig) = deployDSC.run();

        console.log("Fetching network configuration...");
        (tokenAddresses, priceFeedAddresses,) = helperConfig.getFullNetworkConfig();
        weth = ERC20Mock(tokenAddresses[0]);
        wbtc = ERC20Mock(tokenAddresses[1]);
        ethPriceFeed = AggregatorV3Interface(priceFeedAddresses[0]);
        btcPriceFeed = AggregatorV3Interface(priceFeedAddresses[1]);

        vm.deal(BOB, STARTING_BALANCE);
        vm.deal(ALICE, STARTING_BALANCE);

        //Lets also send Bob and Alice some WBTC and WETH
        vm.startPrank(address(1));
        weth.transfer(BOB, STARTING_BALANCE);
        weth.transfer(ALICE, STARTING_BALANCE);
        wbtc.transfer(BOB, STARTING_BALANCE);
        wbtc.transfer(ALICE, STARTING_BALANCE);
        vm.stopPrank();

        // Bob needs to approve the DSCEngine to manage his WETH and WBTC
        vm.startPrank(BOB);
        weth.approve(address(dscEngine), STARTING_BALANCE);
        wbtc.approve(address(dscEngine), STARTING_BALANCE);
        vm.stopPrank();

        // Alice needs to approve the DSCEngine to manage her WETH and WBTC
        vm.startPrank(ALICE);
        weth.approve(address(dscEngine), STARTING_BALANCE);
        wbtc.approve(address(dscEngine), STARTING_BALANCE);

        vm.stopPrank();
    }

    //Modifiers

    modifier bobDepositedCollateral() {
        vm.prank(BOB);
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        _;
    }

    modifier bobDepositedCollateralAndMinted() {
        vm.startPrank(BOB);
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, DSC_MINTED);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        vm.stopPrank();
        _;
    }

    modifier bobDepositedAndMintedAndPriceCrash() {
        vm.startPrank(BOB);
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, DSC_MINTED);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        MockV3Aggregator(address(ethPriceFeed)).updateAnswer(ETH_PRICE_CRASH);
        vm.stopPrank();
        _;
    }

    modifier aliceDepositedCollateralAndMinted() {
        vm.startPrank(ALICE);
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL_SUPER_OVER, DSC_MINTED);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        vm.stopPrank();
        _;
    }

    ////////////////////////////////
    ///// Constructor Tests ///////
    ///////////////////////////////
    address[] public tokenAddressesForTest;
    address[] public priceFeedAddressesForTest;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddressesForTest.push(address(weth));
        priceFeedAddressesForTest.push(address(ethPriceFeed));
        priceFeedAddressesForTest.push(address(btcPriceFeed));

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        DSCEngine dscTest = new DSCEngine(tokenAddressesForTest, priceFeedAddressesForTest, address(dsc));
        dscTest;
    }

    ////////////////////////////////
    /////// Price Feed Tests ///////
    ///////////////////////////////
    function testGetUsdValue() public view {
        uint256 usdValue = dscEngine.getUsdValue(address(weth), AMOUNT_COLLATERAL);
        assertEq(usdValue, AMOUNT_COLLATERAL_USD, "USD value of 10 WETH should be 40000");
    }

    function testTotalSupplyOfDSC() public view {
        uint256 totalSupply = dsc.totalSupply();
        assertEq(totalSupply, ZERO, "Total supply of DSC should be 0");
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 70 ether;
        // $70000 btc, $70 USD = 0.001 BTC
        uint256 expectedBtcAmount = 0.001 ether;
        uint256 btcAmount = dscEngine.getTokenAmountFromUsd(address(wbtc), usdAmount);
        assertEq(btcAmount, expectedBtcAmount, "Btc amount should be 0.001");
    }

    ////////////////////////////////
    //// depositCollateralTest /////
    ///////////////////////////////

    function testBobsBalanceIsCorrectAfterDeposit() external {
        vm.prank(BOB);
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        assertEq(weth.balanceOf(BOB), STARTING_BALANCE - AMOUNT_COLLATERAL, "Bob should have 990 WETH");
    }

    function testRevertIfCollateralZero() external {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(address(weth), ZERO);
        vm.stopPrank();
    }

    function testRevertIfUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("Random Token", "RAN", BOB, AMOUNT_COLLATERAL);
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    function testCollatoralIsDepositedSuccessfully() external {
        vm.prank(BOB);
        vm.expectEmit();
        emit CollateralDeposited(BOB, address(weth), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
    }

    function testCollatoralIsPresent() external bobDepositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(BOB);
        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(BOB);
        assertEq(totalDscMinted, expectedDscMinted, "Total DSC minted should be 0");
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd, "Collateral value in USD should be 40000");
    }

    function testDepositCollateralFailsIfApprovalRevoked() external {
        vm.startPrank(BOB);
        weth.approve(address(dscEngine), ZERO);
        vm.expectRevert();
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////
    // depositCollateralAndMintTest //
    ///////////////////////////////

    function testDscIsMintedSuccessfully() external {
        vm.prank(BOB);
        //We should be able to mint -> 10 WETH = 40000 USD / 2 = 20000 DSC
        uint256 expectedDscMinted = DSC_MINTED;
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, expectedDscMinted);
        assertEq(dsc.balanceOf(BOB), expectedDscMinted, "Bob should have 20000 DSC");
    }

    function testDscIsNotMintedIfAttemptingToMintTooMuch() external {
        vm.prank(BOB);
        uint256 tooMuchDsc = 40000e18;
        uint256 expectedHealthFactor = 5e17; // 0.5

        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBelowOne.selector, expectedHealthFactor)
        );
        dscEngine.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, tooMuchDsc);
    }

    //////////////
    // mintDsc //
    /////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(BOB);
        weth.approve(address(mockDsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MintingFailed.selector);
        mockDsce.depositCollateralAndMintDsc(address(weth), AMOUNT_COLLATERAL, DSC_MINTED);
        vm.stopPrank();
    }

    function testMintDsc() external bobDepositedCollateralAndMinted {
        assertEq(dsc.balanceOf(BOB), DSC_MINTED, "Bob should have 20000 DSC");
    }

    function testMintDscFailsIfHealthFactorBelowOne() external bobDepositedCollateral {
        vm.prank(BOB);
        uint256 dscToMint = 40000e18;
        uint256 expectedHealthFactor = 5e17; // 0.5
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBelowOne.selector, expectedHealthFactor)
        );
        dscEngine.mintDsc(dscToMint);
    }

    //////////////////
    // healthFactor //
    //////////////////

    function testHealthFactorAfterDeposit() external bobDepositedCollateral {
        uint256 expectedHealthFactor = type(uint256).max;
        uint256 healthFactor = dscEngine.getHealthFactor(BOB);
        console.log(healthFactor);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be max uint256");
    }

    function testHealthFactorIsExpectedAfterMint() external bobDepositedCollateral {
        //Bob deposits 10 ETH = 40,000 USD -> With 10,000 DSC minted, health factor should be 2
        uint256 dscToMint = 10000e18;
        vm.prank(BOB);
        dscEngine.mintDsc(dscToMint);
        uint256 expectedHealthFactor = 2e18; // 2
        uint256 healthFactor = dscEngine.getHealthFactor(BOB);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2");
    }

    function testHealthFactorIsExpectedAfterRedeem() external bobDepositedCollateral {
        //Bob deposits 10 ETH = 40,000 USD -> With 10,000 DSC minted, health factor should be 2
        uint256 dscToMint = 10000e18;
        vm.prank(BOB);
        dscEngine.mintDsc(dscToMint);
        uint256 expectedHealthFactor = 2e18; // 2
        uint256 healthFactor = dscEngine.getHealthFactor(BOB);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2");

        //Bob withdraws 5 ETH = 20,000 USD -> With 10,000 DSC minted, health factor should be 1
        vm.prank(BOB);
        dscEngine.redeemCollateral(address(weth), 5 ether);
        expectedHealthFactor = 1e18; // 1
        healthFactor = dscEngine.getHealthFactor(BOB);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 1");
    }

    function testHealthFactorFallsBelowOneAfterPriceFall() external bobDepositedCollateralAndMinted {
        //Bob deposited 10 ETH = 40,000 USD -> With 20,000 DSC minted, health factor should be 1
        assertEq(dscEngine.getHealthFactor(BOB), 1e18, "Health factor should be 1");

        MockV3Aggregator(address(ethPriceFeed)).updateAnswer(ETH_PRICE_CRASH);

        // After price crash, health factor should be cut if half
        uint256 expectedHealthFactor = 8.75e17; // 0.875
        assertEq(dscEngine.getHealthFactor(BOB), expectedHealthFactor, "Health factor should be 0.5");
    }

    function testHealthFactorCanGoBelowOne() public bobDepositedAndMintedAndPriceCrash {
        uint256 userHealthFactor = dscEngine.getHealthFactor(BOB);

        assert(userHealthFactor < 1e18);
    }

    //////////////////////////
    // redeemCollateralTest //
    //////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [address(ethPriceFeed)];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(BOB, AMOUNT_COLLATERAL);
        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(BOB);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__RedeemFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfCollateralZeroOnRedeem() external bobDepositedCollateral {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(address(weth), 0);
        vm.stopPrank();
    }

    function testCollateralSuccessfullyRedeemed() external bobDepositedCollateral {
        vm.prank(BOB);
        dscEngine.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        assertEq(weth.balanceOf(BOB), STARTING_BALANCE, "Bob's balance should be back to 1000 WETH");
    }

    function testRevertIfTryingToRedeemTooMuch() external bobDepositedCollateral {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
        dscEngine.redeemCollateral(address(weth), AMOUNT_COLLATERAL + 1);
    }

    function testCorrectAmountOfTokenRemainsAfterRedeem() external bobDepositedCollateral {
        uint256 halfCollateral = AMOUNT_COLLATERAL / 2;
        vm.prank(BOB);
        dscEngine.redeemCollateral(address(weth), halfCollateral);
        uint256 expectedTokenInContract = AMOUNT_COLLATERAL - halfCollateral;
        assertEq(
            dscEngine.getUsersTokenCollateralDeposited(BOB, address(weth)),
            expectedTokenInContract,
            "Contract should have 5 WETH"
        );
    }

    function testRevertIfHealthFactorBelowOneOnRedeem() external bobDepositedCollateralAndMinted {
        uint256 expectedHealthFactor = 5e17; // 0.5
        uint256 halfCollateral = AMOUNT_COLLATERAL / 2;
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBelowOne.selector, expectedHealthFactor)
        );
        dscEngine.redeemCollateral(address(weth), halfCollateral);
    }

    /////////////////////////////////
    // redeemCollateralAndBurnTest //
    ////////////////////////////////

    function testRevertIfCollateralZeroOnRedeemAndBurn() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(address(weth), ZERO, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfBurnZeroOnRedeemAndBurn() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(address(weth), AMOUNT_COLLATERAL, ZERO);
    }

    function testRevertIfTryingToRedeemTooMuchOnRedeemAndBurn() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
        dscEngine.redeemCollateralForDsc(address(weth), AMOUNT_COLLATERAL + 1, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfTryingToBurnTooMuchOnRedeemAndBurn() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientDSC.selector);
        dscEngine.redeemCollateralForDsc(address(weth), AMOUNT_COLLATERAL, DSC_MINTED + 1);
    }

    function testCorrectAmountOfDscBurntOnRedeemAndBurn() external bobDepositedCollateralAndMinted {
        uint256 halfDsc = DSC_MINTED / 2;
        uint256 halfCollateral = AMOUNT_COLLATERAL / 2;
        vm.startPrank(BOB);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        dscEngine.redeemCollateralForDsc(address(weth), halfCollateral, halfDsc);
        vm.stopPrank();
        uint256 expectedDscInContract = (DSC_MINTED) / 2;

        //Get Contract Information
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(BOB);
        console.log("Total DSC Minted: ", totalDscMinted);

        assertEq(totalDscMinted, expectedDscInContract, "Contract should have 10000 DSC");
    }

    //////////////
    // burnDsc //
    /////////////

    function testRevertIfBurnZeroOnBurnDsc() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.burnDsc(ZERO);
        vm.stopPrank();
    }

    function testRevertIfTryingToBurnTooMuchOnBurnDsc() external bobDepositedCollateralAndMinted {
        vm.startPrank(BOB);
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientDSC.selector);
        dscEngine.burnDsc(DSC_MINTED + 1);
    }

    function testCorrectAmountOfDscBurntOnBurnDsc() external bobDepositedCollateralAndMinted {
        uint256 halfDsc = DSC_MINTED / 2;
        vm.startPrank(BOB);
        dsc.approve(address(dscEngine), (DSC_MINTED));
        dscEngine.burnDsc(halfDsc);
        vm.stopPrank();
        uint256 expectedDscInContract = (DSC_MINTED) / 2;

        //Get Contract Information
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(BOB);
        console.log("Total DSC Minted: ", totalDscMinted);

        assertEq(totalDscMinted, expectedDscInContract, "Contract should have 10000 DSC");
    }

    //////////////////
    // liquidataion //
    /////////////////

    /*
    *
    * Bob's health factor should be 0.5
    *
    */
    function testHealthFactorImprovedByLiquidation()
        external
        bobDepositedAndMintedAndPriceCrash
        aliceDepositedCollateralAndMinted
    {
        uint256 bobsPreLiquidationHealthFactor = dscEngine.getHealthFactor(BOB);
        vm.startPrank(ALICE);
        dscEngine.liquidate(address(weth), BOB, DSC_DEBT_TO_COVER);
        uint256 bobsPostLiquidationHealthFactor = dscEngine.getHealthFactor(BOB);
        assert(bobsPreLiquidationHealthFactor < bobsPostLiquidationHealthFactor);
    }

    function testAliceLiquidationFailsIfNotEnoughDsc()
        external
        bobDepositedAndMintedAndPriceCrash
        aliceDepositedCollateralAndMinted
    {
        vm.startPrank(ALICE);

        //Burn Alice DSC
        dscEngine.burnDsc(DSC_MINTED);

        vm.expectRevert();
        dscEngine.liquidate(address(weth), BOB, DSC_MINTED);
    }

    function testAliceHealthFactorRemainsTheSameAfterLiquidation()
        external
        bobDepositedAndMintedAndPriceCrash
        aliceDepositedCollateralAndMinted
    {
        uint256 totalDscMinted;
        uint256 alicePreLiquidationHealthFactor = dscEngine.getHealthFactor(ALICE);
        console.log("Alice's health factor before liquidation: ", alicePreLiquidationHealthFactor);
        console.log("Alice's DSC balance pre liquidation: ", dsc.balanceOf(ALICE));
        (totalDscMinted,) = dscEngine.getAccountInformation(ALICE);
        console.log("Alice's total DSC minted pre liquidation: ", totalDscMinted);
        vm.startPrank(ALICE);
        dscEngine.liquidate(address(weth), BOB, DSC_DEBT_TO_COVER);
        uint256 alicePostLiquidationHealthFactor = dscEngine.getHealthFactor(ALICE);
        console.log("Alice's health factor after liquidation: ", alicePostLiquidationHealthFactor);
        console.log("Alice's DSC balance post liquidation: ", dsc.balanceOf(ALICE));
        (totalDscMinted,) = dscEngine.getAccountInformation(ALICE);
        console.log("Alice's total DSC minted post liquidation: ", totalDscMinted);
        assertEq(alicePreLiquidationHealthFactor, alicePostLiquidationHealthFactor);
    }

    function testAliceDscBalanceIsReducedAfterLiquidation()
        external
        bobDepositedAndMintedAndPriceCrash
        aliceDepositedCollateralAndMinted
    {
        uint256 totalDscMinted;
        uint256 alicePreLiquidationDscBalance = dsc.balanceOf(ALICE);
        (totalDscMinted,) = dscEngine.getAccountInformation(ALICE);
        vm.startPrank(ALICE);
        dscEngine.liquidate(address(weth), BOB, DSC_DEBT_TO_COVER);
        uint256 alicePostLiquidationDscBalance = dsc.balanceOf(ALICE);
        assert(alicePreLiquidationDscBalance > alicePostLiquidationDscBalance);
    }

    function testCantLiquidateGoodHealthFactor()
        external
        bobDepositedCollateralAndMinted
        aliceDepositedCollateralAndMinted
    {
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOk.selector, 1e18));
        dscEngine.liquidate(address(weth), BOB, DSC_DEBT_TO_COVER);
    }

    function testLiquidationPayoutIsCorrect()
        external
        bobDepositedAndMintedAndPriceCrash
        aliceDepositedCollateralAndMinted
    {
        uint256 alicePreLiquidationWethBalance = weth.balanceOf(ALICE);
        console.log("Alice's WETH balance before liquidation: ", alicePreLiquidationWethBalance);
        vm.startPrank(ALICE);
        dscEngine.liquidate(address(weth), BOB, DSC_DEBT_TO_COVER);
        uint256 alicePostLiquidationWethBalance = weth.balanceOf(ALICE);
        console.log("Alice's WETH balance after liquidation: ", alicePostLiquidationWethBalance);
        assert(alicePreLiquidationWethBalance < alicePostLiquidationWethBalance);
    }

    ////////////////////////////////
    // View & Pure function tests //
    ///////////////////////////////

    function testGetUsersTotalTokenCollateralDeposited() external bobDepositedCollateral {
        DSCEngine.TokenDeposit[] memory tokenDeposits = dscEngine.getUsersTotalTokenCollateralDeposited(BOB);
        assertEq(tokenDeposits[0].token, address(weth), "Token should be WETH");
        assertEq(tokenDeposits[0].amount, AMOUNT_COLLATERAL, "Amount should be 10");
    }
}
