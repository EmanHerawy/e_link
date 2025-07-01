package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/Layr-Labs/hourglass-monorepo/ponos/pkg/performer/server"
	performerV1 "github.com/Layr-Labs/protocol-apis/gen/protos/eigenlayer/hourglass/v1/performer"
	"go.uber.org/zap"
)

// TaskWorker implements counter reading for oracle-based validation
type TaskWorker struct {
	logger    *zap.Logger
	ethClient *ethclient.Client
}

// CounterTask represents the task payload structure
type CounterTask struct {
	CounterAddress string `json:"counterAddress"`
	BlockNumber    uint64 `json:"blockNumber"`
}

// Counter contract ABI for reading the getCurrentValue function
const CounterABI = `[
	{
		"inputs": [],
		"name": "getCurrentValue",
		"outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
		"stateMutability": "view",
		"type": "function"
	}
]`

func NewTaskWorker(logger *zap.Logger) *TaskWorker {
	// Connect to local Ethereum client (anvil)
	client, err := ethclient.Dial("http://localhost:8545")
	if err != nil {
		logger.Sugar().Fatalw("Failed to connect to Ethereum client", "error", err)
	}

	return &TaskWorker{
		logger:    logger,
		ethClient: client,
	}
}

func (tw *TaskWorker) ValidateTask(t *performerV1.TaskRequest) error {
	tw.logger.Sugar().Infow("Validating counter reading task",
		zap.Any("task", t),
	)

	// Parse task payload to validate it's a counter reading task
	var task CounterTask
	if err := json.Unmarshal(t.Payload, &task); err != nil {
		return fmt.Errorf("invalid task payload: %w", err)
	}

	// Basic validation
	if task.CounterAddress == "" {
		return fmt.Errorf("counter address is required")
	}

	if task.BlockNumber == 0 {
		return fmt.Errorf("block number is required")
	}

	// Validate counter address format
	if !common.IsHexAddress(task.CounterAddress) {
		return fmt.Errorf("invalid counter address format")
	}

	tw.logger.Sugar().Infow("Task validation successful",
		"counterAddress", task.CounterAddress,
		"blockNumber", task.BlockNumber,
	)

	return nil
}

func (tw *TaskWorker) HandleTask(t *performerV1.TaskRequest) (*performerV1.TaskResponse, error) {
	tw.logger.Sugar().Infow("Handling counter reading task",
		zap.Any("task", t),
	)

	// Parse task payload
	var task CounterTask
	if err := json.Unmarshal(t.Payload, &task); err != nil {
		return nil, fmt.Errorf("failed to parse task payload: %w", err)
	}

	// Read counter value at specified block
	counterValue, err := tw.readCounterAtBlock(task.CounterAddress, task.BlockNumber)
	if err != nil {
		tw.logger.Sugar().Errorw("Failed to read counter value", "error", err)
		return &performerV1.TaskResponse{
			TaskId: t.TaskId,
			Result: nil,
		}, err
	}

	// Prepare result - encode as the smart contract expects (uint256, uint256)
	result, err := abi.Arguments{{Type: abi.Type{T: abi.UintTy, Size: 256}}, {Type: abi.Type{T: abi.UintTy, Size: 256}}}.Pack(
		counterValue,
		big.NewInt(int64(task.BlockNumber)),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to encode result: %w", err)
	}

	tw.logger.Sugar().Infow("Successfully handled counter reading task",
		"counterAddress", task.CounterAddress,
		"counterValue", counterValue,
		"blockNumber", task.BlockNumber,
	)

	return &performerV1.TaskResponse{
		TaskId: t.TaskId,
		Result: result,
	}, nil
}

// readCounterAtBlock reads the counter value at a specific block
func (tw *TaskWorker) readCounterAtBlock(counterAddr string, blockNumber uint64) (*big.Int, error) {
	// Parse counter ABI
	parsedABI, err := abi.JSON(strings.NewReader(CounterABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse counter ABI: %w", err)
	}

	// Prepare call data for getCurrentValue()
	callData, err := parsedABI.Pack("getCurrentValue")
	if err != nil {
		return nil, fmt.Errorf("failed to pack call data: %w", err)
	}

	// Make the call at specific block
	msg := ethereum.CallMsg{
		To:   &common.Address{},
		Data: callData,
	}
	copy(msg.To[:], common.HexToAddress(counterAddr).Bytes())

	result, err := tw.ethClient.CallContract(context.Background(), msg, big.NewInt(int64(blockNumber)))
	if err != nil {
		return nil, fmt.Errorf("failed to call counter contract: %w", err)
	}

	// Unpack the result
	var counterValue *big.Int
	err = parsedABI.UnpackIntoInterface(&counterValue, "getCurrentValue", result)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack result: %w", err)
	}

	tw.logger.Sugar().Infow("Successfully read counter value",
		"counterAddress", counterAddr,
		"blockNumber", blockNumber,
		"value", counterValue,
	)

	return counterValue, nil
}

func main() {
	ctx := context.Background()
	l, _ := zap.NewProduction()

	// Create task worker
	w := NewTaskWorker(l)

	// Create and start the Hourglass performer server
	pp, err := server.NewPonosPerformerWithRpcServer(&server.PonosPerformerConfig{
		Port:    8080,
		Timeout: 5 * time.Second,
	}, w, l)
	if err != nil {
		panic(fmt.Errorf("failed to create performer: %w", err))
	}

	l.Info("Starting Counter Reading AVS with Oracle-based Validation")
	if err := pp.Start(ctx); err != nil {
		panic(err)
	}
}