// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Counter
 * @notice Simple counter contract for AVS validation testing
 * @dev Operators will read the counter value at specific blocks for validation
 */
contract Counter {
    /// @notice Current counter value
    uint256 public counter;
    
    /// @notice Event emitted when counter is updated
    event CounterUpdated(uint256 indexed newValue, uint256 indexed blockNumber, address indexed updater);
    
    /**
     * @notice Initialize counter to 0
     */
    constructor() {
        counter = 0;
    }
    
    /**
     * @notice Set the counter to a specific value
     * @dev This creates state changes that AVS operators can validate
     * @param _newValue The new counter value to set
     */
    function setCounter(uint256 _newValue) external {
        counter = _newValue;
        emit CounterUpdated(_newValue, block.number, msg.sender);
    }
    
    /**
     * @notice Increment the counter by 1
     * @dev Alternative way to update counter for testing
     */
    function increment() external {
        counter++;
        emit CounterUpdated(counter, block.number, msg.sender);
    }
    
    /**
     * @notice Decrement the counter by 1 (with underflow protection)
     * @dev Alternative way to update counter for testing
     */
    function decrement() external {
        require(counter > 0, "Counter cannot go below zero");
        counter--;
        emit CounterUpdated(counter, block.number, msg.sender);
    }
    
    /**
     * @notice Get the current counter value
     * @return The current counter value
     */
    function getCurrentValue() external view returns (uint256) {
        return counter;
    }
    
  
}