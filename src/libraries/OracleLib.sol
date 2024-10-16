//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

/*
 * @title OracleLib
 * @author Charlie Mack 
 * @dev Library for Oracle contract
 * @notice This library is used to check the Chainlink oracle
 * If a price is stale, the function will revert, and render the DSCEngine unusable 
 * We want the DSCEngine to freeze if the price is stale
 * 
 * So if Chainlink explodes and you have money in this contract - too bad.
 */

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 timeElapsed = block.timestamp - updatedAt;

        if (timeElapsed > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }
}
