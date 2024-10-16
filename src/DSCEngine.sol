//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.18;

/*
 * @title DSCEngine
 * @author Charlie Mack
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This contract is the mechanism that governs the pegging of the Decentralized Stable Coin to the USD
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC should be overcollateralized to ensure that the system can handle large price swings
 * at no point should the collarateral be <= 100% of the DSC minted
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and burning DSC
 * @notice This contract is VERY loosly based on the MakerDAO system
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    ///////////////
    //  Errors   //
    //////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__MustBeAllowedToken();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__DepositFailed();
    error DSCEngine__HealthFactorBelowOne(uint256 healthFactor);
    error DSCEngine__MintingFailed();
    error DSCEngine__InsufficientCollateral();
    error DSCEngine__RedeemFailed();
    error DSCEngine__InsufficientDSC();
    error DSCEngine__BurningFailed();
    error DSCEngine__HealthFactorOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 startingHealthFactor, uint256 endingHealthFactor);

    //////////////
    //  Types  //
    /////////////
    struct TokenDeposit {
        address token;
        uint256 amount;
    }

    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    //  State Variables   //
    ////////////////////////
    uint256 private constant ADDITIONAL_PRICE_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% Overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidating

    DecentralizedStableCoin private i_dsc;

    mapping(address token => address priceFeed) private s_priceFeeds; // Mapping of token address to price feed address
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposit; // Mapping of token address to collateral balance
    mapping(address user => uint256 amountDscMinted) private s_dscMinted; // Mapping of user address to DSC balance
    address[] private s_collateralTokens; // Array of allowed tokens

    ///////////////
    // Events   //
    //////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom, address redeemedTo, address indexed token, uint256 amount);

    ///////////////
    // Modifiers //
    //////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__MustBeAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    //////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        i_dsc = DecentralizedStableCoin(dscAddress);

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_collateralTokens.push(tokenAddresses[i]);
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
    }

    /////////////////////////
    // External Functions //
    ////////////////////////

    /*
     * @notice This function allows a user to deposit collateral and mint DSC
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function is a convenience function that allows a user to deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice This function allows a user to deposit collateral
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposit[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // Transfer the collateral from the user to this contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__DepositFailed();
        }
    }

    //Check the collateral ratio & w/ price feeds

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintingFailed();
        }
    }

    /*
     * @notice This function allows a user to redeem collateral and burn DSC
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateralToRedeem The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function is a convenience function that allows a user to redeem collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateralToRedeem);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender);
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender); // i don't think this is necessary
    }

    /*
    * @param user The address of the user to liquidate
    * @param collateral The address of the collateral token
    * @param debtToCover The amount of DSC to cover
    * @notice This function allows anyone to liquidate a user if their health factor goes below 1
    * and then receive their collateral at a discount
    * @notice You can partially liquidate a user
    * @notice You will get a liquidation bonus if you liquidate a user
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized
    * @notice A known bug would be if the protocol would be if the protocol were 100% or less collateralized, then it wouldnt make sense to liquidate as they would get back less that then the DSC burnt
    * For example, if the price of the collateral plummeted before anyone could be liquidated.
    * 
    * Follow CEI: Checks, Effects, Interactions
    * 
    */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk(startingUserHealthFactor);
        }

        // Bad User: $140 ETH, $100 DSC - health factor = 0.7
        // Liquidator: Paying $100 DSC = ?? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        // Covering 10000e18 DSC with $2000e8 ETH = 5e18 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // 5e18 * 10 / 100 = 0.5e18

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        //Price cut by half so we need to work out the amount it needs to be to cover the debt
        // 10k isnt covering it

        _redeemCollateral(tokenCollateralAddress, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved(startingUserHealthFactor, endingUserHealthFactor);
        }
        _revertIfHealthFactorBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    ///////////////////////////////////
    // Private & Internal Functions //
    /////////////////////////////////

    /*
    * @dev Low-level internal function to burn DSC
    * @notice Dont call unless from a function checking health factor
    *
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        uint256 userDsc = s_dscMinted[onBehalfOf];
        if (userDsc < amountDscToBurn) {
            revert DSCEngine__InsufficientDSC();
        }

        s_dscMinted[onBehalfOf] -= amountDscToBurn;

        // Burn the DSC
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__BurningFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        // Check if the user has enough collateral to redeem
        uint256 userCollateral = s_collateralDeposit[from][tokenCollateralAddress];
        if (userCollateral < amountCollateral) {
            revert DSCEngine__InsufficientCollateral();
        }

        s_collateralDeposit[from][tokenCollateralAddress] -= amountCollateral;

        // Transfer the collateral from this contract to the user
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DSCEngine__RedeemFailed();
        }
    }

    /*
    * Returns the total DSC minted and the total collateral value in USD
    * Then we can work out the health factor and how much the user is 
    */
    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_dscMinted[user];
        uint256 collarateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (totalDscMinted, collarateralValueInUsd);
    }

    /*
    * Returns how close the user is to liquidation
    * If the user goes below 1, they will be liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValue) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralValue);
    }

    function _revertIfHealthFactorBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowOne(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //////////////////////////////////////
    // Public & External View Functions //
    /////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address tokenCollateralAddress, uint256 usdAmountInWei)
        public
        view
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenCollateralAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10) = 0.0005
        // ($10000e18 * 1e18) / ($2000e8 * 1e10) = 5
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_PRICE_FEED_PRECISION));
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposit[user][token];

            totalCollateralValue += getUsdValue(token, amount);
        }

        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 valueInUsd) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // ($4000e18 * 1e10) * 10e18 / 1e18 = 40000e18
        return ((uint256(price) * ADDITIONAL_PRICE_FEED_PRECISION) * amount) / PRECISION;
    }

    /*
    * Returns the total DSC minted and the total collateral value in USD
    * Then we can work out the health factor and how much the user is 
    */
    function getAccountInformation(address user) external view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }

    /*
    * @notice This function allows you to see how much collateral a user has deposited for a specific token
    *
    */
    function getUsersTokenCollateralDeposited(address user, address token) external view returns (uint256) {
        return s_collateralDeposit[user][token];
    }

    function getUsersTotalTokenCollateralDeposited(address user) external view returns (TokenDeposit[] memory) {
        TokenDeposit[] memory deposits = new TokenDeposit[](s_collateralTokens.length);

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposit[user][token];
            deposits[i] = TokenDeposit(token, amount);
        }

        return deposits;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
