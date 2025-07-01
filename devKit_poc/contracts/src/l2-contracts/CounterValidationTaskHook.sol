// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Chainlink CCIP imports
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import "./AVSTaskHook.sol";
import "../Counter.sol";

/**
 * @title CounterValidationTaskHook
 * @notice Unified AVS Task Hook with integrated Chainlink Functions for counter validation
 * @dev Handles Hourglass task lifecycle and oracle-based validation in one contract
 */
contract CounterValidationTaskHook is IAVSTaskHook, FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;
    
    /// @notice Counter contract instance
    Counter public counterContract;
    
    /// @notice Chainlink Functions configuration
    uint64 public subscriptionId;
    uint32 public gasLimit = 300000;
    bytes32 public donId;
    
    /// @notice Structure for counter reading tasks
    struct CounterTask {
        bytes32 taskHash;
        uint256 targetBlock;
        uint256 submittedValue;
        address aggregator;
        uint256 timestamp;
        ValidationStatus status;
        bytes32 chainlinkRequestId;
        uint256 actualValue;
    }
    
    /// @notice Task validation status
    enum ValidationStatus {
        Created,
        Submitted,
        Validating,
        Validated,
        Failed
    }
    
    /// @notice Operator reputation data
    struct OperatorInfo {
        int256 reputation;           // Can be negative for slashed operators
        uint256 totalRewards;       // Total rewards earned
        uint256 totalSlashed;       // Total amount slashed
        uint256 taskCount;          // Total tasks completed
        uint256 successCount;       // Successful tasks
        bool isActive;              // Whether operator is active
        uint256 lastActivityTime;   // Last task completion time
    }
    
    /// @notice Mapping from task hash to counter task data
    mapping(bytes32 => CounterTask) public counterTasks;
    
    /// @notice Mapping from Chainlink request ID to task hash
    mapping(bytes32 => bytes32) public chainlinkRequestToTask;
    
    /// @notice Mapping from operator address to reputation info
    mapping(address => OperatorInfo) public operators;
    
    /// @notice Array of all registered operators
    address[] public registeredOperators;
    
    /// @notice Mapping to check if operator is registered
    mapping(address => bool) public isRegistered;
    
    /// @notice Configuration variables for rewards/slashing
    uint256 public rewardAmount = 1 ether;
    uint256 public slashAmount = 0.5 ether;
    int256 public reputationIncrease = 10;
    int256 public reputationDecrease = 25;
    
    /// @notice Constants
    int256 public constant INITIAL_REPUTATION = 100;
    int256 public constant MIN_REPUTATION = -1000;
    int256 public constant MAX_REPUTATION = 1000;
    
    /// @notice JavaScript source code for counter reading
    string private constant COUNTER_READER_SOURCE = 
        "const counterAddress = args[0];"
        "const blockNumber = args[1];"
        "const rpcUrl = secrets.RPC_URL;"
        "if (!counterAddress || !blockNumber) {"
        "    throw new Error('Missing required parameters');"
        "}"
        "if (!rpcUrl) {"
        "    throw new Error('RPC_URL secret not configured');"
        "}"
        "const blockNumberHex = blockNumber.startsWith('0x') ? blockNumber : `0x${parseInt(blockNumber).toString(16)}`;"
        "const GET_CURRENT_VALUE_SELECTOR = '0xf2c9ecd8';"
        "const callData = GET_CURRENT_VALUE_SELECTOR;"
        "const makeCounterCall = async () => {"
        "    const rpcRequest = {"
        "        method: 'POST',"
        "        url: rpcUrl,"
        "        headers: {'Content-Type': 'application/json'},"
        "        data: {"
        "            jsonrpc: '2.0',"
        "            method: 'eth_call',"
        "            params: [{"
        "                to: counterAddress,"
        "                data: callData"
        "            }, blockNumberHex],"
        "            id: 1"
        "        }"
        "    };"
        "    const response = await Functions.makeHttpRequest(rpcRequest);"
        "    if (response.error) throw new Error(`HTTP Error: ${JSON.stringify(response.error)}`);"
        "    const result = response.data;"
        "    if (result.error) throw new Error(`RPC Error: ${JSON.stringify(result.error)}`);"
        "    return result.result;"
        "};"
        "const decodeUint256 = (hexResult) => {"
        "    if (!hexResult || hexResult === '0x' || hexResult === '0x0') return '0';"
        "    const cleanHex = hexResult.replace('0x', '');"
        "    return BigInt('0x' + cleanHex).toString();"
        "};"
        "const executeCounterRead = async () => {"
        "    try {"
        "        const counterHex = await makeCounterCall();"
        "        const counterDecimal = decodeUint256(counterHex);"
        "        console.log(`Counter read successful: ${counterDecimal}`);"
        "        return Functions.encodeString(counterDecimal);"
        "    } catch (error) {"
        "        console.log(`Counter read failed: ${error.message}`);"
        "        throw new Error(`Failed to read counter: ${error.message}`);"
        "    }"
        "};"
        "return executeCounterRead();";
    
    /// @notice Events
    event TaskCreated(
        bytes32 indexed taskHash,
        uint256 targetBlock,
        uint256 timestamp
    );
    
    event TaskResultSubmitted(
        bytes32 indexed taskHash,
        address indexed aggregator,
        uint256 submittedValue
    );
    
    event ValidationRequested(
        bytes32 indexed requestId,
        bytes32 indexed taskHash,
        uint256 targetBlock
    );
    
    event TaskValidated(
        bytes32 indexed taskHash,
        bool isValid,
        uint256 actualValue,
        uint256 submittedValue
    );
    
    event OperatorRegistered(address indexed operator, int256 initialReputation);
    
    event ReputationUpdated(
        address indexed operator,
        int256 oldReputation,
        int256 newReputation,
        int256 change
    );
    
    event OperatorRewarded(address indexed operator, uint256 amount);
    event OperatorSlashed(address indexed operator, uint256 amount);
    
    /// @notice Custom errors
    error TaskNotFound(bytes32 taskHash);
    error TaskAlreadySubmitted(bytes32 taskHash);
    error InvalidBlockNumber(uint256 blockNumber);
    error TaskNotInValidatingState();
    error OperatorNotRegistered(address operator);
    error OperatorAlreadyRegistered(address operator);
    error UnexpectedRequestID(bytes32 requestId);
    error InvalidReputationChange();
    
    /**
     * @notice Initialize the Counter Validation Task Hook
     * @param router Chainlink Functions router address
     * @param _donId Decentralized Oracle Network ID
     * @param _subscriptionId Chainlink Functions subscription ID
     * @param _counterContract Address of the Counter contract
     */
    constructor(
        address router,
        bytes32 _donId,
        uint64 _subscriptionId,
        address _counterContract
    ) FunctionsClient(router) ConfirmedOwner(msg.sender) {
        donId = _donId;
        subscriptionId = _subscriptionId;
        counterContract = Counter(_counterContract);
    }
    
    // ============ HOURGLASS AVS TASK HOOK FUNCTIONS ============
    
    /**
     * @notice Validate task creation (called by TaskMailbox)
     * @param caller The address creating the task
     * @param operatorSet The operator set for this task
     * @param payload The task payload containing target block number
     */
    function validatePreTaskCreation(
        address caller,
        OperatorSet memory operatorSet,
        bytes memory payload
    ) external view override {
        // Decode target block from payload
        uint256 targetBlock = abi.decode(payload, (uint256));
        
        // Validate block number is not in future
        if (targetBlock >= block.number) {
            revert InvalidBlockNumber(targetBlock);
        }
        
        // Additional validation logic can be added here
    }
    
    /**
     * @notice Handle post task creation (called by TaskMailbox)
     * @param taskHash The hash of the created task
     */
    function validatePostTaskCreation(
        bytes32 taskHash
    ) external override {
        // Store basic task info
        counterTasks[taskHash] = CounterTask({
            taskHash: taskHash,
            targetBlock: 0, // Would be extracted from TaskMailbox in real implementation
            submittedValue: 0,
            aggregator: address(0),
            timestamp: block.timestamp,
            status: ValidationStatus.Created,
            chainlinkRequestId: bytes32(0),
            actualValue: 0
        });
        
        emit TaskCreated(taskHash, 0, block.timestamp);
    }
    
    /**
     * @notice Validate task result submission (called by TaskMailbox)
     * @param taskHash The hash of the task
     * @param cert The BLS certificate from aggregator
     */
    function validateTaskResultSubmission(
        bytes32 taskHash,
        IBN254CertificateVerifier.BN254Certificate memory cert
    ) external override {
        CounterTask storage task = counterTasks[taskHash];
        
        if (task.taskHash == bytes32(0)) revert TaskNotFound(taskHash);
        if (task.status != ValidationStatus.Created) revert TaskAlreadySubmitted(taskHash);
        
        // Extract submitted value and target block from TaskMailbox result
        // For demo purposes, using placeholder values
        uint256 submittedValue = _extractSubmittedValue(taskHash);
        uint256 targetBlock = _extractTargetBlock(taskHash);
        address aggregator = _extractAggregator(cert);
        
        // Update task with submitted result
        task.submittedValue = submittedValue;
        task.targetBlock = targetBlock;
        task.aggregator = aggregator;
        task.status = ValidationStatus.Submitted;
        
        // Register operator if not already registered
        if (!isRegistered[aggregator]) {
            _registerOperator(aggregator);
        }
        
        emit TaskResultSubmitted(taskHash, aggregator, submittedValue);
        
        // Initiate Chainlink validation
        _initiateChainlinkValidation(taskHash, targetBlock, submittedValue);
    }
    
    // ============ CHAINLINK FUNCTIONS ============
    
    /**
     * @notice Initiate Chainlink Functions validation
     * @param taskHash The task hash
     * @param targetBlock The target block number
     * @param submittedValue The value submitted by operators
     */
    function _initiateChainlinkValidation(
        bytes32 taskHash,
        uint256 targetBlock,
        uint256 submittedValue
    ) internal {
        CounterTask storage task = counterTasks[taskHash];
        task.status = ValidationStatus.Validating;
        
        // Prepare function arguments
        string[] memory args = new string[](2);
        args[0] = _addressToString(address(counterContract));
        args[1] = _uint256ToString(targetBlock);
        
        // Build Chainlink Functions request
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(COUNTER_READER_SOURCE);
        req.setArgs(args);
        
        // Send the request
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donId
        );
        
        task.chainlinkRequestId = requestId;
        chainlinkRequestToTask[requestId] = taskHash;
        
        emit ValidationRequested(requestId, taskHash, targetBlock);
    }
    
    /**
     * @notice Chainlink Functions callback
     * @param requestId The request ID
     * @param response The response from Chainlink Functions
     * @param err Any error from Chainlink Functions
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        bytes32 taskHash = chainlinkRequestToTask[requestId];
        CounterTask storage task = counterTasks[taskHash];
        
        if (task.taskHash == bytes32(0)) {
            revert UnexpectedRequestID(requestId);
        }
        
        if (task.status != ValidationStatus.Validating) revert TaskNotInValidatingState();
        
        if (err.length > 0) {
            // Handle error case
            task.status = ValidationStatus.Failed;
            return;
        }
        
        // Decode the counter value from response
        string memory counterValueStr = abi.decode(response, (string));
        uint256 actualValue = _stringToUint256(counterValueStr);
        
        task.actualValue = actualValue;
        bool isValid = (task.submittedValue == actualValue);
        task.status = isValid ? ValidationStatus.Validated : ValidationStatus.Failed;
        
        emit TaskValidated(taskHash, isValid, actualValue, task.submittedValue);
        
        // Update reputation and handle rewards/slashing
        _handleReputationUpdate(task.aggregator, isValid);
    }
    
    // ============ REPUTATION MANAGEMENT ============
    
    /**
     * @notice Register a new operator
     * @param operator Address of the operator to register
     */
    function _registerOperator(address operator) internal {
        if (isRegistered[operator]) revert OperatorAlreadyRegistered(operator);
        
        operators[operator] = OperatorInfo({
            reputation: INITIAL_REPUTATION,
            totalRewards: 0,
            totalSlashed: 0,
            taskCount: 0,
            successCount: 0,
            isActive: true,
            lastActivityTime: block.timestamp
        });
        
        registeredOperators.push(operator);
        isRegistered[operator] = true;
        
        emit OperatorRegistered(operator, INITIAL_REPUTATION);
    }
    
    /**
     * @notice Handle reputation updates and rewards/slashing
     * @param operator The operator address
     * @param isValid Whether the validation was successful
     */
    function _handleReputationUpdate(address operator, bool isValid) internal {
        if (!isRegistered[operator]) revert OperatorNotRegistered(operator);
        
        OperatorInfo storage info = operators[operator];
        int256 oldReputation = info.reputation;
        
        info.taskCount++;
        info.lastActivityTime = block.timestamp;
        
        if (isValid) {
            // Reward successful validation
            info.successCount++;
            info.reputation += reputationIncrease;
            if (info.reputation > MAX_REPUTATION) {
                info.reputation = MAX_REPUTATION;
            }
            
            info.totalRewards += rewardAmount;
            emit OperatorRewarded(operator, rewardAmount);
        } else {
            // Slash for incorrect submission
            info.reputation -= reputationDecrease;
            if (info.reputation < MIN_REPUTATION) {
                info.reputation = MIN_REPUTATION;
            }
            
            info.totalSlashed += slashAmount;
            emit OperatorSlashed(operator, slashAmount);
        }
        
        emit ReputationUpdated(operator, oldReputation, info.reputation, info.reputation - oldReputation);
    }
    
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @notice Get task details
     * @param taskHash The task hash
     * @return task The counter task data
     */
    function getTask(bytes32 taskHash) external view returns (CounterTask memory) {
        return counterTasks[taskHash];
    }
    
    /**
     * @notice Get operator reputation details
     * @param operator Address of the operator
     * @return info The operator's reputation data
     */
    function getOperatorInfo(address operator) external view returns (OperatorInfo memory) {
        if (!isRegistered[operator]) revert OperatorNotRegistered(operator);
        return operators[operator];
    }
    
    /**
     * @notice Get operator success rate as a percentage
     * @param operator Address of the operator
     * @return successRate Success rate (0-100)
     */
    function getOperatorSuccessRate(address operator) external view returns (uint256) {
        if (!isRegistered[operator]) revert OperatorNotRegistered(operator);
        
        OperatorInfo memory info = operators[operator];
        if (info.taskCount == 0) return 0;
        
        return (info.successCount * 100) / info.taskCount;
    }
    
    /**
     * @notice Get all registered operators
     * @return operators Array of operator addresses
     */
    function getAllOperators() external view returns (address[] memory) {
        return registeredOperators;
    }
    
    // ============ HELPER FUNCTIONS ============
    
    /**
     * @notice Extract submitted value from task (placeholder)
     * @param taskHash The task hash
     * @return submittedValue The submitted value
     */
    function _extractSubmittedValue(bytes32 taskHash) internal pure returns (uint256) {
        // In real implementation, extract from TaskMailbox result
        return uint256(taskHash) % 1000;
    }
    
    /**
     * @notice Extract target block from task (placeholder)
     * @param taskHash The task hash
     * @return targetBlock The target block number
     */
    function _extractTargetBlock(bytes32 taskHash) internal view returns (uint256) {
        // In real implementation, extract from TaskMailbox payload
        return block.number - 10;
    }
    
    /**
     * @notice Extract aggregator from certificate (placeholder)
     * @param cert The BLS certificate
     * @return aggregator The aggregator address
     */
    function _extractAggregator(IBN254CertificateVerifier.BN254Certificate memory cert) internal view returns (address) {
        // In real implementation, extract from certificate
        return msg.sender;
    }
    
    function _addressToString(address addr) private pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
    
    function _uint256ToString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _stringToUint256(string memory str) private pure returns (uint256) {
        bytes memory b = bytes(str);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 digit = uint8(b[i]) - 48;
            require(digit <= 9, "Invalid character in number string");
            result = result * 10 + digit;
        }
        return result;
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    /**
     * @notice Update configuration parameters
     */
    function updateRewardAmount(uint256 newAmount) external onlyOwner {
        rewardAmount = newAmount;
    }
    
    function updateSlashAmount(uint256 newAmount) external onlyOwner {
        slashAmount = newAmount;
    }
    
    function updateReputationValues(int256 increase, int256 decrease) external onlyOwner {
        reputationIncrease = increase;
        reputationDecrease = decrease;
    }
    
    function updateSubscriptionId(uint64 newSubscriptionId) external onlyOwner {
        subscriptionId = newSubscriptionId;
    }
    
    function updateGasLimit(uint32 newGasLimit) external onlyOwner {
        gasLimit = newGasLimit;
    }
}