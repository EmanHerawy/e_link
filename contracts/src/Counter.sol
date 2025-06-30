// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Counter
 * @notice Simple counter contract for AVS validation testing
 * @dev Operators will read the counter value at specific blocks
 */
contract Counter {
    /// @notice Current counter value
    uint256 public counter;
    
    /// @notice Event emitted when counter is incremented
    event CounterIncremented(uint256 indexed newValue, uint256 indexed blockNumber);
    
    /**
     * @notice Initialize counter to 0
     */
    constructor() {
        counter = 0;
    }
    
    /**
     * @notice Increment the counter by 1
     * @dev This creates state changes that operators can validate
     */
    function increment() external {
        counter++;
        emit CounterIncremented(counter, block.number);
    }
    
    /**
     * @notice Get the current counter value
     * @return The current counter value
     */
    function getCurrentValue() external view returns (uint256) {
        return counter;
    }
}