// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {OperatorSet} from "@eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

import {ITaskMailbox} from "@hourglass-monorepo/src/interfaces/core/ITaskMailbox.sol";
import {IAVSTaskHook} from "@hourglass-monorepo/src/interfaces/avs/l2/IAVSTaskHook.sol";
import {IBN254CertificateVerifier} from "@hourglass-monorepo/src/interfaces/avs/l2/IBN254CertificateVerifier.sol";

contract AVSTaskHook is IAVSTaskHook, FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;
    
    /// @notice Counter contract address
    address public counterContractAddress;
    address public mailBox;
    
    /// @notice Chainlink Functions configuration
    uint64 public subscriptionId;
    uint32 public gasLimit = 300000;
    bytes32 public donId;
    
    /// @notice Structure for counter reading tasks
    struct CounterTask {
        bytes32 taskHash;
        uint256 targetBlock;
        uint256 submittedValue;
        uint256 timestamp;
        bytes32 chainlinkRequestId;
        uint256 actualValue;
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
    error OnlyMailBox();
    error UnexpectedRequestID(bytes32 requestId);
    error TaskNotFound(bytes32 taskHash);
    error OperatorNotRegistered(address operator);
    error OperatorAlreadyRegistered(address operator);
    
    modifier onlyMailBox() {
        if(msg.sender != mailBox){
            revert OnlyMailBox();
        }
        _;
    }
    
    /**
     * @notice Initialize the Counter Validation Task Hook
     * @param _mailBox MailBox address
     * @param router Chainlink Functions router address
     * @param _donId Decentralized Oracle Network ID
     * @param _subscriptionId Chainlink Functions subscription ID
     * @param _counterContract Address of the Counter contract
     */
    constructor(
        address _mailBox,
        address router,
        bytes32 _donId,
        uint64 _subscriptionId,
        address _counterContract
    ) FunctionsClient(router) ConfirmedOwner(msg.sender) {
        mailBox = _mailBox;
        donId = _donId;
        subscriptionId = _subscriptionId;
        counterContractAddress = _counterContract;
    }
    
    /// @notice Allow only mailbox to call it 
    function validatePreTaskCreation(
        address, /*caller*/
        OperatorSet memory, /*operatorSet*/
        bytes memory /*payload*/
    ) external view {
        //TODO: Implement
    }

    function validatePostTaskCreation(
        bytes32 /*taskHash*/
    ) external {
        //TODO: Implement
    }

    function validateTaskResultSubmission(
        bytes32 taskHash,
        IBN254CertificateVerifier.BN254Certificate memory /*cert*/
    ) external override onlyMailBox {
        // Get task result from mailbox and decode it 
        bytes memory result = ITaskMailbox(mailBox).getTaskResult(taskHash);
        (uint256 counterValue, uint256 blockNumber) = abi.decode(result, (uint256, uint256));

        // Update task with submitted values
        CounterTask storage task = counterTasks[taskHash];
        task.submittedValue = counterValue;
        task.targetBlock = blockNumber;
        
        // Get operator from certificate (simplified - in real implementation extract from cert)
        address operator = tx.origin; // Placeholder - should extract from cert
        
        // Register operator if not already registered
        if (!isRegistered[operator]) {
            _registerOperator(operator);
        }

        // Initiate Chainlink validation
        _initiateChainlinkValidation(taskHash, blockNumber, counterValue);
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
        task.submittedValue = submittedValue;
        
        // Prepare function arguments
        string[] memory args = new string[](2);
        args[0] = _addressToString(counterContractAddress);
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
        
        if (err.length > 0) {
            // Handle error case
            return;
        }
        
        // Decode the counter value from response
        string memory counterValueStr = abi.decode(response, (string));
        uint256 actualValue = _stringToUint256(counterValueStr);
        
        task.actualValue = actualValue;
        bool isValid = (task.submittedValue == actualValue);
        
        emit TaskValidated(taskHash, isValid, actualValue, task.submittedValue);
        
        // Get operator address (simplified - in real implementation track during submission)
        address operator = tx.origin; // Placeholder
        
        // Update reputation and handle rewards/slashing
        _handleReputationUpdate(operator, isValid);
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