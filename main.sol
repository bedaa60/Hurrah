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

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        governor = 0x7F4a2c8E1b3D9f0A5c6E8b1D4f7A0c3E6b9D2f5;
        settlementKeeper = 0x8E5b3c9F2a4D0e6B7c9F1a4D7e0B3c6F9a2D5e8;
        feeCollector = 0x9F6c4d0A3b5E1f7C8d0A3b6E9f2C5d8A1b4E7c0;
        bridgeRelay = 0xA07d5e1B4c6F2a8D9e1B4c7F0a3D6e9B2c5F8a1;
        feeBps = 25; // 0.25%
        minOrderAmount = 1e15; // 0.001 ether
        maxOrderAmount = 1e24; // 1M ether
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGovernor() {
        if (msg.sender != governor) revert HRH_NotGovernor();
        _;
    }

    modifier onlySettlementKeeper() {
        if (msg.sender != settlementKeeper) revert HRH_NotSettlementKeeper();
        _;
    }

    modifier onlyFeeCollector() {
        if (msg.sender != feeCollector) revert HRH_NotFeeCollector();
        _;
    }

    modifier onlyBridgeRelay() {
        if (msg.sender != bridgeRelay) revert HRH_NotBridgeRelay();
        _;
    }

    modifier whenNotPaused() {
        if (orderBookPaused) revert HRH_BookPaused();
        _;
    }

    modifier nonReentrant() {
        if (_guard != 0) revert HRH_Reentrant();
        _guard = 1;
        _;
        _guard = 0;
    }

    // -------------------------------------------------------------------------
    // ADMIN
    // -------------------------------------------------------------------------

    function setFeeBps(uint256 newFeeBps) external onlyGovernor {
        if (newFeeBps > HRH_MAX_FEE_BPS) revert HRH_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsChanged(prev, newFeeBps, block.number);
    }

    function setOrderBookPaused(bool paused) external onlyGovernor {
        orderBookPaused = paused;
        emit OrderBookPaused(paused, block.number);
    }

    function setMinOrderAmount(uint256 newMin) external onlyGovernor {
        if (newMin > maxOrderAmount) revert HRH_InvalidAmount();
        uint256 prev = minOrderAmount;
        minOrderAmount = newMin;
        emit MinOrderAmountChanged(prev, newMin, block.number);
    }

    function setMaxOrderAmount(uint256 newMax) external onlyGovernor {
        if (newMax < minOrderAmount) revert HRH_InvalidAmount();
        uint256 prev = maxOrderAmount;
        maxOrderAmount = newMax;
        emit MaxOrderAmountChanged(prev, newMax, block.number);
    }

    // -------------------------------------------------------------------------
    // ORDER BOOK: POST
    // -------------------------------------------------------------------------

    function postOrder(
        bytes32 orderId,
        uint8 side,
        uint64 chainIdOrigin,
        uint64 chainIdSettle,
        bytes32 assetIn,
        bytes32 assetOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint64 expiryBlock
    ) external whenNotPaused nonReentrant {
        if (orderId == bytes32(0)) revert HRH_ZeroOrderId();
        if (_orders[orderId].exists) revert HRH_OrderNotFound();
        if (orderCount >= HRH_MAX_ORDERS) revert HRH_MaxOrdersReached();
        if (side > HRH_SIDE_SELL) revert HRH_InvalidSide();
        if (amountIn < minOrderAmount) revert HRH_AmountBelowMin();
        if (amountIn > maxOrderAmount) revert HRH_AmountAboveMax();
        if (chainIdOrigin == 0 || chainIdSettle == 0) revert HRH_InvalidChainId();
        if (expiryBlock <= block.number) revert HRH_OrderExpired();
        if (expiryBlock - block.number < HRH_MIN_EXPIRY_OFFSET) revert HRH_InvalidExpiry();
        if (expiryBlock - block.number > HRH_MAX_EXPIRY_OFFSET) revert HRH_InvalidExpiry();

        Order memory o = Order({
            orderId: orderId,
            maker: msg.sender,
            side: side,
            chainIdOrigin: chainIdOrigin,
            chainIdSettle: chainIdSettle,
            assetIn: assetIn,
            assetOut: assetOut,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            amountFilledIn: 0,
            expiryBlock: expiryBlock,
            exists: true,
            cancelled: false,
            settled: false,
            postedAt: uint64(block.timestamp)
        });

        _orders[orderId] = o;
        _orderIds.push(orderId);
        _makerOrderIds[msg.sender].push(orderId);
        _orderIdsByOriginChain[chainIdOrigin].push(orderId);
        _orderIdsBySettleChain[chainIdSettle].push(orderId);
        orderCount++;

        emit OrderPosted(
            orderId,
            msg.sender,
            side,
            chainIdOrigin,
            chainIdSettle,
            assetIn,
            assetOut,
            amountIn,
            amountOutMin,
            expiryBlock,
            uint64(block.timestamp)
        );
    }

    // -------------------------------------------------------------------------
    // ORDER BOOK: FILL
    // -------------------------------------------------------------------------

    function fillOrder(
        bytes32 orderId,
        uint256 fillAmountIn,
        uint256 fillAmountOut
    ) external payable whenNotPaused nonReentrant {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        if (o.cancelled) revert HRH_OrderCancelled();
        if (o.maker == msg.sender) revert HRH_MakerCannotTake();
        if (block.number > o.expiryBlock) revert HRH_OrderExpired();
        uint256 remaining = o.amountIn - o.amountFilledIn;
        if (remaining == 0) revert HRH_OrderAlreadyFilled();
        if (fillAmountIn == 0 || fillAmountIn > remaining) revert HRH_InvalidFillAmount();
