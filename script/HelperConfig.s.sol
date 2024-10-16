//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mock/ERC20Mock.sol";

contract HelperConfig is Script {
    NetworkConfig private activeNetworkConfig;

    uint256 public constant INITIAL_TOKEN_BALANCE = 10_000_000_000 ether;

    uint8 public constant ETH_DECIMALS = 8;
    int256 public constant ETH_PRICE = 4000e8;

    uint8 public constant BTC_DECIMALS = 8;
    int256 public constant BTC_PRICE = 70000e8;

    uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    struct NetworkConfig {
        address[] tokenAddresses;
        address[] priceFeedAddresses;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getFullNetworkConfig() public view returns (address[] memory, address[] memory, uint256) {
        return (
            activeNetworkConfig.tokenAddresses, activeNetworkConfig.priceFeedAddresses, activeNetworkConfig.deployerKey
        );
    }

    function getMainnetEthConfig() private view returns (NetworkConfig memory) {
        address[] memory tokenAddresses = new address[](2);
        address[] memory priceFeedAddresses = new address[](2);

        tokenAddresses[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        tokenAddresses[1] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC

        priceFeedAddresses[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WETH/USD
        priceFeedAddresses[1] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // WBTC/USD

        return NetworkConfig({
            tokenAddresses: tokenAddresses,
            priceFeedAddresses: priceFeedAddresses,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getSepoliaEthConfig() private view returns (NetworkConfig memory) {
        address[] memory tokenAddresses = new address[](2);
        address[] memory priceFeedAddresses = new address[](2);

        tokenAddresses[0] = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // WETH
        tokenAddresses[1] = 0x92f3B59a79bFf5dc60c0d59eA13a44D082B2bdFC; // WBTC

        priceFeedAddresses[0] = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // WETH/USD
        priceFeedAddresses[1] = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43; // WBTC/USD

        return NetworkConfig({
            tokenAddresses: tokenAddresses,
            priceFeedAddresses: priceFeedAddresses,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.tokenAddresses.length != 0) {
            return activeNetworkConfig;
        }

        address[] memory tokenAddresses = new address[](2);
        address[] memory priceFeedAddresses = new address[](2);

        vm.startBroadcast();
        //Create the price feeds
        MockV3Aggregator wethPriceFeed = new MockV3Aggregator(ETH_DECIMALS, ETH_PRICE);
        MockV3Aggregator wbtcPriceFeed = new MockV3Aggregator(BTC_DECIMALS, BTC_PRICE);

        //Create the tokens
        ERC20Mock wethToken = new ERC20Mock("WETH", "WETH", address(1), INITIAL_TOKEN_BALANCE);
        ERC20Mock wbtcToken = new ERC20Mock("WBTC", "WBTC", address(1), INITIAL_TOKEN_BALANCE);

        vm.stopBroadcast();

        tokenAddresses[0] = address(wethToken);
        tokenAddresses[1] = address(wbtcToken);

        priceFeedAddresses[0] = address(wethPriceFeed);
        priceFeedAddresses[1] = address(wbtcPriceFeed);

        return NetworkConfig({
            tokenAddresses: tokenAddresses,
            priceFeedAddresses: priceFeedAddresses,
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
