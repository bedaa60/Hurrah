// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Hurrah
/// @notice Cross-chain OTC settlement and order book: makers post limit orders with chain and asset
///         identifiers; takers fill against the book; settlement keeper finalizes cross-chain legs.
/// @dev Order lifecycle: Post -> (Fill / PartialFill / Cancel) -> Settle. Fee collector receives
///      a configurable basis-point fee on filled volume. All role addresses are immutable and
///      set at deployment. Safe for mainnet when deployed with trusted roles.
///
/// Design notes: Order book is chain-agnostic; chainIdOrigin and chainIdSettle identify source
/// and destination chains for cross-chain settlement. Settlement keeper attests completion on
/// the settle chain; bridge relay can be used for relaying proofs. Fee is taken from the out
/// amount (quote) so maker receives amountOut - fee. Reentrancy guard on all state-changing
/// paths; pull pattern for fees and refunds. No ETH custody beyond taker->maker and taker->feeCollector
/// during fill. Settlement refs are one-time-use to prevent replay across chains.

contract Hurrah {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event OrderPosted(
        bytes32 indexed orderId,
        address indexed maker,
        uint8 side,
        uint64 chainIdOrigin,
        uint64 chainIdSettle,
        bytes32 assetIn,
        bytes32 assetOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint64 expiryBlock,
        uint64 postedAt
    );

    event OrderFilled(
        bytes32 indexed orderId,
        address indexed taker,
        uint256 fillAmountIn,
        uint256 fillAmountOut,
        uint64 filledAt
    );

    event OrderCancelled(bytes32 indexed orderId, address indexed maker, uint64 cancelledAt);
    event SettlementFinalized(
        bytes32 indexed orderId,
        uint64 chainIdSettle,
        bytes32 settlementRef,
        uint64 finalizedAt
    );
    event GovernorChanged(address indexed previous, address indexed current, uint256 atBlock);
    event SettlementKeeperChanged(address indexed previous, address indexed current, uint256 atBlock);
    event FeeCollectorChanged(address indexed previous, address indexed current, uint256 atBlock);
    event BridgeRelayChanged(address indexed previous, address indexed current, uint256 atBlock);
    event FeeBpsChanged(uint256 previous, uint256 current, uint256 atBlock);
    event OrderBookPaused(bool paused, uint256 atBlock);
    event MinOrderAmountChanged(uint256 previous, uint256 current, uint256 atBlock);
    event MaxOrderAmountChanged(uint256 previous, uint256 current, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error HRH_NotGovernor();
    error HRH_NotSettlementKeeper();
    error HRH_NotFeeCollector();
    error HRH_NotBridgeRelay();
    error HRH_ZeroAddress();
    error HRH_ZeroOrderId();
    error HRH_OrderNotFound();
    error HRH_OrderAlreadyFilled();
    error HRH_OrderCancelled();
    error HRH_OrderExpired();
    error HRH_InvalidSide();
    error HRH_InvalidAmount();
    error HRH_InvalidFillAmount();
    error HRH_InvalidChainId();
    error HRH_BookPaused();
    error HRH_Reentrant();
    error HRH_TransferFailed();
    error HRH_InsufficientValue();
    error HRH_InvalidFeeBps();
    error HRH_AlreadySettled();
    error HRH_SettlementRefUsed();
    error HRH_MakerCannotTake();
    error HRH_MaxOrdersReached();
    error HRH_AmountBelowMin();
    error HRH_AmountAboveMax();
    error HRH_InvalidExpiry();
    error HRH_InvalidIndex();
    error HRH_EmptyBatch();
    error HRH_NotMaker();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant HRH_FEE_DENOM_BPS = 10_000;
    uint256 public constant HRH_MAX_FEE_BPS = 300; // 3%
    uint256 public constant HRH_SIDE_BUY = 0;
    uint256 public constant HRH_SIDE_SELL = 1;
    uint256 public constant HRH_MAX_ORDERS = 150_000;
    uint256 public constant HRH_MIN_EXPIRY_OFFSET = 2;
    uint256 public constant HRH_MAX_EXPIRY_OFFSET = 2_000_000;
    uint256 public constant HRH_MAX_BATCH_CANCEL = 128;
    uint256 public constant HRH_MAX_BATCH_FILL = 64;

    bytes32 public constant HRH_NAMESPACE = keccak256("Hurrah.otc.v2");
    bytes32 public constant HRH_VERSION = keccak256("hurrah.version.2");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable governor;
    address public immutable settlementKeeper;
    address public immutable feeCollector;
    address public immutable bridgeRelay;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct Order {
        bytes32 orderId;
        address maker;
        uint8 side;
        uint64 chainIdOrigin;
        uint64 chainIdSettle;
        bytes32 assetIn;
        bytes32 assetOut;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountFilledIn;
        uint64 expiryBlock;
        bool exists;
        bool cancelled;
        bool settled;
        uint64 postedAt;
    }

    struct SettlementRecord {
        bytes32 orderId;
        bytes32 settlementRef;
        uint64 chainIdSettle;
        uint64 finalizedAt;
    }

    uint256 public feeBps;
    uint256 public minOrderAmount;
    uint256 public maxOrderAmount;
    bool public orderBookPaused;
    uint256 private _guard;
    uint256 public orderCount;

    mapping(bytes32 => Order) private _orders;
    mapping(bytes32 => SettlementRecord) private _settlements;
    mapping(bytes32 => bool) private _settlementRefUsed;
    bytes32[] private _orderIds;
    mapping(address => bytes32[]) private _makerOrderIds;
    mapping(uint64 => bytes32[]) private _orderIdsByOriginChain;
    mapping(uint64 => bytes32[]) private _orderIdsBySettleChain;
