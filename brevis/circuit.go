package brevis

import (
	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// This example circuit analyzes the swap events between USDC and ETH/WETH for a user.

// AppCircuit is a developer-defined circuit that performs checks and data analysis
// over the input Receipt. The proof of this circuit is to be verified in Brevis
// in conjunction with various data validity checks. A final proof is then
// submitted on-chain and expose the output to the developer's contract.
// The Brevis side ensures that all receipts
type AppCircuit struct {
	// You can define your own custom circuit inputs here, but note that they cannot
	// have the `gnark:",public"` tag.
	UserAddr [2]sdk.Uint248
}

var from = common.HexToAddress("0xaefB31e9EEee2822f4C1cBC13B70948b0B5C0b3c")
var from2 = common.HexToAddress("0x3195ee2A3c4Cc67f448767faAdb061472e670223")

func DefaultAppCircuit() *AppCircuit {
	return &AppCircuit{
		UserAddr: [2]sdk.Uint248{sdk.ConstUint248(from), sdk.ConstUint248(from2)},
	}
}

// Your guest circuit must implement the sdk.AppCircuit interface
var _ sdk.AppCircuit = &AppCircuit{}

// sdk.ParseXXX APIs are used to convert Go/EVM data types into circuit types.
// Note that you can only use these outside of circuit (making constant circuit
// variables)

var EventIdSwap = sdk.ParseEventID(
	hexutil.MustDecode("0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"))
var EventIdTransfer = sdk.ParseEventID(
	hexutil.MustDecode("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"))

var RouterAddress = sdk.ConstUint248(
	common.HexToAddress("0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B"))
var UsdcPoolAddress = sdk.ConstUint248(
	common.HexToAddress("0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"))
var UsdcAddress = sdk.ConstUint248(
	common.HexToAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"))
var Salt = sdk.ConstBytes32(
	hexutil.MustDecode("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"))

func (c *AppCircuit) Allocate() (maxReceipts, maxSlots, maxTransactions int) {
	// Allocating regions for different source data. Here, we are allocating 5 data
	// slots for "receipt" data, and none for other data types. Please note that if
	// you allocate it this way and compile your circuit, the circuit structure will
	// always have 5 processing "chips" for receipts and none for others. It means
	// your compiled circuit will always be only able to process up to 5 receipts and
	// cannot process other types unless you change the allocations and recompile.
	return 5, 0, 0
}

func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	u248 := api.Uint248

	receipts := sdk.NewDataStream(api, in.Receipts)

	// Main application logic: Run the assert function on each receipt. The function
	// should return 1 if assertion successes and 0 otherwise
	sdk.AssertEach(receipts, func(l sdk.Receipt) sdk.Uint248 {
		// If the recipient field of the Swap event is uniswap router, it means the user
		// requested native token out. We need to instead check the user's address in the
		// Transfer event emitted by USDC contract
		u248.IsEqual(api.ToUint248(l.Fields[1].Value), RouterAddress)

		assertionPassed := u248.And(
			// Check that the contract address of each log field is the expected contract
			u248.IsEqual(l.Fields[0].Contract, UsdcPoolAddress),
			u248.IsEqual(l.Fields[1].Contract, UsdcPoolAddress),
			u248.IsEqual(l.Fields[2].Contract, UsdcAddress),
			// Check the EventID of the fields are as expected
			u248.IsEqual(l.Fields[0].EventID, EventIdSwap),
			u248.IsEqual(l.Fields[1].EventID, EventIdSwap),
			u248.IsEqual(l.Fields[2].EventID, EventIdTransfer),
			// Check the index of the fields are as expected
			u248.IsZero(l.Fields[0].IsTopic),                     // `amount0` is not a topic field
			u248.IsEqual(l.Fields[0].Index, sdk.ConstUint248(0)), // `amount0` is the 0th data field in the `Swap` event
			l.Fields[1].IsTopic,                                  // `recipient` is a topic field
			u248.IsEqual(l.Fields[1].Index, sdk.ConstUint248(2)), // `recipient` is the 2nd topic field in the `Swap` event
			l.Fields[2].IsTopic,                                  // `from` is a topic field
			u248.IsEqual(l.Fields[2].Index, sdk.ConstUint248(1)), // `from` is the 1st index field in the `Transfer` event
		)
		return assertionPassed
	})

	for _, uint248 := range c.UserAddr {
		api.OutputAddress(uint248)
	}
	return nil
}
