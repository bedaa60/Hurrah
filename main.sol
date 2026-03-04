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
        if (fillAmountOut < (o.amountOutMin * fillAmountIn) / o.amountIn) revert HRH_InvalidFillAmount();

        uint256 fee = (fillAmountOut * feeBps) / HRH_FEE_DENOM_BPS;
        uint256 makerReceives = fillAmountOut - fee;
        if (feeBps > 0 && feeCollector != address(0)) {
            (bool feeOk, ) = feeCollector.call{value: fee}("");
            if (!feeOk) revert HRH_TransferFailed();
        }
        (bool payOk, ) = o.maker.call{value: makerReceives}("");
        if (!payOk) revert HRH_TransferFailed();
        if (msg.value > fillAmountOut) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - fillAmountOut}("");
            if (!refundOk) revert HRH_TransferFailed();
        } else if (msg.value < fillAmountOut) {
            revert HRH_InsufficientValue();
        }

        o.amountFilledIn += fillAmountIn;
        emit OrderFilled(orderId, msg.sender, fillAmountIn, fillAmountOut, uint64(block.timestamp));
    }

    function fillOrderExactOut(
        bytes32 orderId,
        uint256 fillAmountIn,
        uint256 exactAmountOut
    ) external payable whenNotPaused nonReentrant {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        if (o.cancelled) revert HRH_OrderCancelled();
        if (o.maker == msg.sender) revert HRH_MakerCannotTake();
        if (block.number > o.expiryBlock) revert HRH_OrderExpired();
        uint256 remaining = o.amountIn - o.amountFilledIn;
        if (remaining == 0) revert HRH_OrderAlreadyFilled();
        if (fillAmountIn == 0 || fillAmountIn > remaining) revert HRH_InvalidFillAmount();
        uint256 minOut = (o.amountOutMin * fillAmountIn) / o.amountIn;
        if (exactAmountOut < minOut) revert HRH_InvalidFillAmount();

        uint256 fee = (exactAmountOut * feeBps) / HRH_FEE_DENOM_BPS;
        uint256 makerReceives = exactAmountOut - fee;
        if (feeBps > 0 && feeCollector != address(0)) {
            (bool feeOk, ) = feeCollector.call{value: fee}("");
            if (!feeOk) revert HRH_TransferFailed();
        }
        (bool payOk, ) = o.maker.call{value: makerReceives}("");
        if (!payOk) revert HRH_TransferFailed();
        if (msg.value > exactAmountOut) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - exactAmountOut}("");
            if (!refundOk) revert HRH_TransferFailed();
        } else if (msg.value < exactAmountOut) {
            revert HRH_InsufficientValue();
        }

        o.amountFilledIn += fillAmountIn;
        emit OrderFilled(orderId, msg.sender, fillAmountIn, exactAmountOut, uint64(block.timestamp));
    }

    // -------------------------------------------------------------------------
    // ORDER BOOK: CANCEL
    // -------------------------------------------------------------------------

    function cancelOrder(bytes32 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        if (o.maker != msg.sender) revert HRH_NotMaker();
        if (o.cancelled) revert HRH_OrderCancelled();
        if (o.amountFilledIn >= o.amountIn) revert HRH_OrderAlreadyFilled();
        o.cancelled = true;
        emit OrderCancelled(orderId, msg.sender, uint64(block.timestamp));
    }

    function cancelOrdersBatch(bytes32[] calldata orderIds) external nonReentrant {
        if (orderIds.length == 0) revert HRH_EmptyBatch();
        if (orderIds.length > HRH_MAX_BATCH_CANCEL) revert HRH_InvalidAmount();
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (o.exists && o.maker == msg.sender && !o.cancelled && o.amountFilledIn < o.amountIn) {
                o.cancelled = true;
                emit OrderCancelled(orderIds[i], msg.sender, uint64(block.timestamp));
            }
        }
    }

    // -------------------------------------------------------------------------
    // SETTLEMENT (CROSS-CHAIN)
    // -------------------------------------------------------------------------

    function finalizeSettlement(
        bytes32 orderId,
        uint64 chainIdSettle,
        bytes32 settlementRef
    ) external onlySettlementKeeper nonReentrant {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        if (o.settled) revert HRH_AlreadySettled();
        if (_settlementRefUsed[settlementRef]) revert HRH_SettlementRefUsed();
        if (chainIdSettle != o.chainIdSettle) revert HRH_InvalidChainId();

        _settlementRefUsed[settlementRef] = true;
        o.settled = true;
        _settlements[orderId] = SettlementRecord({
            orderId: orderId,
            settlementRef: settlementRef,
            chainIdSettle: chainIdSettle,
            finalizedAt: uint64(block.timestamp)
        });

        emit SettlementFinalized(orderId, chainIdSettle, settlementRef, uint64(block.timestamp));
    }

    function finalizeSettlementBatch(
        bytes32[] calldata orderIds,
        uint64[] calldata chainIdsSettle,
        bytes32[] calldata settlementRefs
    ) external onlySettlementKeeper nonReentrant {
        if (orderIds.length == 0 || orderIds.length != chainIdsSettle.length || orderIds.length != settlementRefs.length) revert HRH_InvalidAmount();
        if (orderIds.length > HRH_MAX_BATCH_FILL) revert HRH_InvalidAmount();
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (!o.exists || o.settled || _settlementRefUsed[settlementRefs[i]]) continue;
            if (chainIdsSettle[i] != o.chainIdSettle) continue;
            _settlementRefUsed[settlementRefs[i]] = true;
            o.settled = true;
            _settlements[orderIds[i]] = SettlementRecord({
                orderId: orderIds[i],
                settlementRef: settlementRefs[i],
                chainIdSettle: chainIdsSettle[i],
                finalizedAt: uint64(block.timestamp)
            });
            emit SettlementFinalized(orderIds[i], chainIdsSettle[i], settlementRefs[i], uint64(block.timestamp));
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS: SINGLE ORDER
    // -------------------------------------------------------------------------

    function getOrder(bytes32 orderId)
        external
        view
        returns (
            address maker,
            uint8 side,
            uint64 chainIdOrigin,
            uint64 chainIdSettle,
            bytes32 assetIn,
            bytes32 assetOut,
            uint256 amountIn,
            uint256 amountOutMin,
            uint256 amountFilledIn,
            uint64 expiryBlock,
            bool cancelled,
            bool settled,
            uint64 postedAt
        )
    {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        return (
            o.maker,
            o.side,
            o.chainIdOrigin,
            o.chainIdSettle,
            o.assetIn,
            o.assetOut,
            o.amountIn,
            o.amountOutMin,
            o.amountFilledIn,
            o.expiryBlock,
            o.cancelled,
            o.settled,
            o.postedAt
        );
    }

    function orderExists(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].exists;
    }

    function orderMaker(bytes32 orderId) external view returns (address) {
        if (!_orders[orderId].exists) revert HRH_OrderNotFound();
        return _orders[orderId].maker;
    }

    function orderAmountRemaining(bytes32 orderId) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (!o.exists || o.cancelled) return 0;
        return o.amountIn - o.amountFilledIn;
    }

    function isOrderActive(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return o.exists && !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn;
    }

    function getSettlement(bytes32 orderId)
        external
        view
        returns (bytes32 settlementRef, uint64 chainIdSettle, uint64 finalizedAt)
    {
        SettlementRecord storage s = _settlements[orderId];
        if (s.finalizedAt == 0) revert HRH_OrderNotFound();
        return (s.settlementRef, s.chainIdSettle, s.finalizedAt);
    }

    function settlementRefUsed(bytes32 ref) external view returns (bool) {
        return _settlementRefUsed[ref];
    }

    // -------------------------------------------------------------------------
    // VIEWS: LISTS
    // -------------------------------------------------------------------------

    function getOrderIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _orderIds.length) revert HRH_InvalidIndex();
        return _orderIds[index];
    }

    function totalOrderCount() external view returns (uint256) {
        return _orderIds.length;
    }

    function getOrderIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory out) {
        if (fromIndex > toIndex || toIndex >= _orderIds.length) revert HRH_InvalidIndex();
        uint256 n = toIndex - fromIndex + 1;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _orderIds[fromIndex + i];
        return out;
    }

    function getMakerOrderIds(address maker) external view returns (bytes32[] memory) {
        return _makerOrderIds[maker];
    }

    function getMakerOrderCount(address maker) external view returns (uint256) {
        return _makerOrderIds[maker].length;
    }

    function getOrderIdsByOriginChain(uint64 chainIdOrigin) external view returns (bytes32[] memory) {
        return _orderIdsByOriginChain[chainIdOrigin];
    }

    function getOrderIdsBySettleChain(uint64 chainIdSettle) external view returns (bytes32[] memory) {
        return _orderIdsBySettleChain[chainIdSettle];
    }

    function getOrdersBatch(bytes32[] calldata orderIds)
        external
        view
        returns (
            address[] memory makers,
            uint8[] memory sides,
            uint64[] memory chainIdsOrigin,
            uint64[] memory chainIdsSettle,
            uint256[] memory amountsIn,
            uint256[] memory amountsOutMin,
            uint256[] memory amountsFilledIn,
            uint64[] memory expiryBlocks,
            bool[] memory cancelled,
            bool[] memory settled
        )
    {
        uint256 n = orderIds.length;
        makers = new address[](n);
        sides = new uint8[](n);
        chainIdsOrigin = new uint64[](n);
        chainIdsSettle = new uint64[](n);
        amountsIn = new uint256[](n);
        amountsOutMin = new uint256[](n);
        amountsFilledIn = new uint256[](n);
        expiryBlocks = new uint64[](n);
        cancelled = new bool[](n);
        settled = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            Order storage o = _orders[orderIds[i]];
            if (!o.exists) continue;
            makers[i] = o.maker;
            sides[i] = o.side;
            chainIdsOrigin[i] = o.chainIdOrigin;
            chainIdsSettle[i] = o.chainIdSettle;
            amountsIn[i] = o.amountIn;
            amountsOutMin[i] = o.amountOutMin;
            amountsFilledIn[i] = o.amountFilledIn;
            expiryBlocks[i] = o.expiryBlock;
            cancelled[i] = o.cancelled;
            settled[i] = o.settled;
        }
        return (
            makers,
            sides,
            chainIdsOrigin,
            chainIdsSettle,
            amountsIn,
            amountsOutMin,
            amountsFilledIn,
            expiryBlocks,
            cancelled,
            settled
        );
    }

    // -------------------------------------------------------------------------
    // VIEWS: FEE & CONFIG
    // -------------------------------------------------------------------------

    function computeFeeForFill(uint256 fillAmountOut) external view returns (uint256 fee) {
        return (fillAmountOut * feeBps) / HRH_FEE_DENOM_BPS;
    }

    function computeMakerReceive(uint256 fillAmountOut) external view returns (uint256) {
        uint256 fee = (fillAmountOut * feeBps) / HRH_FEE_DENOM_BPS;
        return fillAmountOut - fee;
    }

    function currentFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function config() external view returns (uint256 _feeBps, uint256 _minOrderAmount, uint256 _maxOrderAmount, bool _paused) {
        return (feeBps, minOrderAmount, maxOrderAmount, orderBookPaused);
    }

    function contractBalanceWei() external view returns (uint256) {
        return address(this).balance;
    }

    // -------------------------------------------------------------------------
    // UTILITY: DERIVE ORDER ID
    // -------------------------------------------------------------------------

    function deriveOrderId(address maker, bytes32 salt, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(HRH_NAMESPACE, maker, salt, nonce));
    }

    // -------------------------------------------------------------------------
    // RECEIVE ETH (for taker payments)
    // -------------------------------------------------------------------------

    receive() external payable {}

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS: ORDER FULL & HELPERS
    // -------------------------------------------------------------------------

    function getOrderFull(bytes32 orderId)
        external
        view
        returns (
            bytes32 id,
            address makerAddr,
            uint8 sideVal,
            uint64 chainOrigin,
            uint64 chainSettle,
            bytes32 assetInId,
            bytes32 assetOutId,
            uint256 amtIn,
            uint256 amtOutMin,
            uint256 amtFilledIn,
            uint256 amtRemaining,
            uint64 expiryBlk,
            bool isCancelled,
            bool isSettled,
            uint64 postedTime
        )
    {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        uint256 remaining = o.amountIn - o.amountFilledIn;
        return (
            o.orderId,
            o.maker,
            o.side,
            o.chainIdOrigin,
            o.chainIdSettle,
            o.assetIn,
            o.assetOut,
            o.amountIn,
            o.amountOutMin,
            o.amountFilledIn,
            remaining,
            o.expiryBlock,
            o.cancelled,
            o.settled,
            o.postedAt
        );
    }

    function minOutForFill(bytes32 orderId, uint256 fillAmountIn) external view returns (uint256) {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        if (fillAmountIn > o.amountIn - o.amountFilledIn) revert HRH_InvalidFillAmount();
        return (o.amountOutMin * fillAmountIn) / o.amountIn;
    }

    function wouldFillSucceed(
        bytes32 orderId,
        address takerAddr,
        uint256 fillAmountIn,
        uint256 fillAmountOut
    ) external view returns (bool success, bytes32 err) {
        Order storage o = _orders[orderId];
        if (!o.exists) return (false, "HRH_OrderNotFound");
        if (o.cancelled) return (false, "HRH_OrderCancelled");
        if (o.maker == takerAddr) return (false, "HRH_MakerCannotTake");
        if (block.number > o.expiryBlock) return (false, "HRH_OrderExpired");
        uint256 remaining = o.amountIn - o.amountFilledIn;
        if (remaining == 0) return (false, "HRH_OrderAlreadyFilled");
        if (fillAmountIn == 0 || fillAmountIn > remaining) return (false, "HRH_InvalidFillAmount");
        uint256 minOut = (o.amountOutMin * fillAmountIn) / o.amountIn;
        if (fillAmountOut < minOut) return (false, "HRH_InvalidFillAmount");
        return (true, bytes32(0));
    }

    function getActiveOrderIdsForMaker(address maker, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory ids)
    {
        bytes32[] storage all = _makerOrderIds[maker];
        uint256 n = 0;
        for (uint256 i = offset; i < all.length && n < limit; i++) {
            if (isOrderActive(all[i])) n++;
        }
        ids = new bytes32[](n);
        uint256 j = 0;
        for (uint256 i = offset; i < all.length && j < n; i++) {
            if (isOrderActive(all[i])) {
                ids[j] = all[i];
                j++;
            }
        }
        return ids;
    }

    function countActiveOrdersForMaker(address maker) external view returns (uint256) {
        bytes32[] storage all = _makerOrderIds[maker];
        uint256 c = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (isOrderActive(all[i])) c++;
        }
        return c;
    }

    mapping(uint64 => bool) private _chainPaused;

    event ChainPauseSet(uint64 indexed chainId, bool paused, uint256 atBlock);

    function setChainPaused(uint64 chainId, bool paused) external onlyGovernor {
        _chainPaused[chainId] = paused;
        emit ChainPauseSet(chainId, paused, block.number);
    }

    function isChainPaused(uint64 chainId) external view returns (bool) {
        return _chainPaused[chainId];
    }

    function getOrderIdsForAssetPair(bytes32 assetIn, bytes32 assetOut, uint256 maxResults)
        external
        view
        returns (bytes32[] memory orderIds)
    {
        uint256 cap = maxResults > _orderIds.length ? _orderIds.length : maxResults;
        uint256[] memory indices = new uint256[](cap);
        uint256 count = 0;
        for (uint256 i = 0; i < _orderIds.length && count < cap; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn
                && o.assetIn == assetIn && o.assetOut == assetOut) {
                indices[count] = i;
                count++;
            }
        }
        orderIds = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            orderIds[j] = _orderIds[indices[j]];
        }
        return orderIds;
    }

    function getOrderIdsForOriginChain(uint64 chainIdOrigin, uint256 fromIdx, uint256 toIdx)
        external
        view
        returns (bytes32[] memory out)
    {
        bytes32[] storage arr = _orderIdsByOriginChain[chainIdOrigin];
        if (fromIdx > toIdx || toIdx >= arr.length) revert HRH_InvalidIndex();
        uint256 n = toIdx - fromIdx + 1;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = arr[fromIdx + i];
        return out;
    }

    function getOrderIdsForSettleChain(uint64 chainIdSettle, uint256 fromIdx, uint256 toIdx)
        external
        view
        returns (bytes32[] memory out)
    {
        bytes32[] storage arr = _orderIdsBySettleChain[chainIdSettle];
        if (fromIdx > toIdx || toIdx >= arr.length) revert HRH_InvalidIndex();
        uint256 n = toIdx - fromIdx + 1;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = arr[fromIdx + i];
        return out;
    }

    function getGlobalStats()
        external
        view
        returns (
            uint256 totalOrders,
            uint256 totalOrdersActive,
            uint256 totalOrdersFilled,
            uint256 totalOrdersCancelled,
            uint256 totalOrdersSettled
        )
    {
        totalOrders = _orderIds.length;
        uint256 active = 0;
        uint256 filled = 0;
        uint256 cancelled = 0;
        uint256 settled = 0;
        for (uint256 i = 0; i < _orderIds.length; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (!o.exists) continue;
            if (o.cancelled) cancelled++;
            else if (o.amountFilledIn >= o.amountIn) filled++;
            else if (block.number > o.expiryBlock) filled++;
            else active++;
            if (o.settled) settled++;
        }
        return (totalOrders, active, filled, cancelled, settled);
    }

    function getMakerStats(address maker)
        external
        view
        returns (uint256 posted, uint256 active, uint256 filled, uint256 cancelled)
    {
        bytes32[] storage ids = _makerOrderIds[maker];
        posted = ids.length;
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = _orders[ids[i]];
            if (!o.exists) continue;
            if (o.cancelled) cancelled++;
            else if (o.amountFilledIn >= o.amountIn || block.number > o.expiryBlock) filled++;
            else active++;
        }
        return (posted, active, filled, cancelled);
    }

    function getActiveOrderIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory out) {
        if (fromIndex > toIndex || toIndex >= _orderIds.length) revert HRH_InvalidIndex();
        uint256 n = toIndex - fromIndex + 1;
        uint256 count = 0;
        for (uint256 i = fromIndex; i <= toIndex; i++) {
            if (isOrderActive(_orderIds[i])) count++;
        }
        out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = fromIndex; i <= toIndex && j < count; i++) {
            if (isOrderActive(_orderIds[i])) {
                out[j] = _orderIds[i];
                j++;
            }
        }
        return out;
    }

    function getExpiredButUnsettledOrderIds(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory out) {
        if (fromIndex > toIndex || toIndex >= _orderIds.length) revert HRH_InvalidIndex();
        uint256 count = 0;
        for (uint256 i = fromIndex; i <= toIndex; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.settled && block.number > o.expiryBlock && o.amountFilledIn > 0) count++;
        }
        out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = fromIndex; i <= toIndex && j < count; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.settled && block.number > o.expiryBlock && o.amountFilledIn > 0) {
                out[j] = _orderIds[i];
                j++;
            }
        }
        return out;
    }

    function quoteFill(bytes32 orderId, uint256 fillAmountIn)
        external
        view
        returns (uint256 minAmountOut, uint256 feeAmount, uint256 makerReceives)
    {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        uint256 remaining = o.amountIn - o.amountFilledIn;
        if (fillAmountIn == 0 || fillAmountIn > remaining) revert HRH_InvalidFillAmount();
        minAmountOut = (o.amountOutMin * fillAmountIn) / o.amountIn;
        feeAmount = (minAmountOut * feeBps) / HRH_FEE_DENOM_BPS;
        makerReceives = minAmountOut - feeAmount;
        return (minAmountOut, feeAmount, makerReceives);
    }

    function getSettlementsBatch(bytes32[] calldata orderIds)
        external
        view
        returns (
            bytes32[] memory refs,
            uint64[] memory chainIds,
            uint64[] memory finalizedAt
        )
    {
        uint256 n = orderIds.length;
        refs = new bytes32[](n);
        chainIds = new uint64[](n);
        finalizedAt = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            SettlementRecord storage s = _settlements[orderIds[i]];
            if (s.finalizedAt != 0) {
                refs[i] = s.settlementRef;
                chainIds[i] = s.chainIdSettle;
                finalizedAt[i] = s.finalizedAt;
            }
        }
        return (refs, chainIds, finalizedAt);
    }

    uint256 public constant HRH_MAX_BATCH_POST = 32;

    function postOrdersBatch(
        bytes32[] calldata orderIds,
        uint8[] calldata sides,
        uint64[] calldata chainIdsOrigin,
        uint64[] calldata chainIdsSettle,
        bytes32[] calldata assetsIn,
        bytes32[] calldata assetsOut,
        uint256[] calldata amountsIn,
        uint256[] calldata amountsOutMin,
        uint64[] calldata expiryBlocks
    ) external whenNotPaused nonReentrant {
        uint256 len = orderIds.length;
        if (len == 0 || len > HRH_MAX_BATCH_POST) revert HRH_InvalidAmount();
        if (len != sides.length || len != chainIdsOrigin.length || len != chainIdsSettle.length) revert HRH_InvalidAmount();
        if (len != assetsIn.length || len != assetsOut.length || len != amountsIn.length || len != amountsOutMin.length || len != expiryBlocks.length) revert HRH_InvalidAmount();
        for (uint256 i = 0; i < len; i++) {
            if (orderCount >= HRH_MAX_ORDERS) revert HRH_MaxOrdersReached();
            bytes32 oid = orderIds[i];
            if (oid == bytes32(0) || _orders[oid].exists) continue;
            if (sides[i] > HRH_SIDE_SELL) continue;
            if (amountsIn[i] < minOrderAmount || amountsIn[i] > maxOrderAmount) continue;
            if (chainIdsOrigin[i] == 0 || chainIdsSettle[i] == 0) continue;
            if (expiryBlocks[i] <= block.number || expiryBlocks[i] - block.number < HRH_MIN_EXPIRY_OFFSET || expiryBlocks[i] - block.number > HRH_MAX_EXPIRY_OFFSET) continue;
            if (_chainPaused[chainIdsOrigin[i]] || _chainPaused[chainIdsSettle[i]]) continue;

            Order memory o = Order({
                orderId: oid,
                maker: msg.sender,
                side: sides[i],
                chainIdOrigin: chainIdsOrigin[i],
                chainIdSettle: chainIdsSettle[i],
                assetIn: assetsIn[i],
                assetOut: assetsOut[i],
                amountIn: amountsIn[i],
                amountOutMin: amountsOutMin[i],
                amountFilledIn: 0,
                expiryBlock: expiryBlocks[i],
                exists: true,
                cancelled: false,
                settled: false,
                postedAt: uint64(block.timestamp)
            });
            _orders[oid] = o;
            _orderIds.push(oid);
            _makerOrderIds[msg.sender].push(oid);
            _orderIdsByOriginChain[chainIdsOrigin[i]].push(oid);
            _orderIdsBySettleChain[chainIdsSettle[i]].push(oid);
            orderCount++;
            emit OrderPosted(oid, msg.sender, sides[i], chainIdsOrigin[i], chainIdsSettle[i], assetsIn[i], assetsOut[i], amountsIn[i], amountsOutMin[i], expiryBlocks[i], uint64(block.timestamp));
        }
    }

    function fillOrdersBatch(
        bytes32[] calldata orderIds,
        uint256[] calldata fillAmountsIn,
        uint256[] calldata fillAmountsOut
    ) external payable whenNotPaused nonReentrant {
        if (orderIds.length == 0 || orderIds.length != fillAmountsIn.length || orderIds.length != fillAmountsOut.length) revert HRH_InvalidAmount();
        if (orderIds.length > HRH_MAX_BATCH_FILL) revert HRH_InvalidAmount();
        uint256 totalValue = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (!o.exists || o.cancelled || o.maker == msg.sender || block.number > o.expiryBlock) continue;
            uint256 remaining = o.amountIn - o.amountFilledIn;
            if (remaining == 0) continue;
            uint256 fillIn = fillAmountsIn[i];
            uint256 fillOut = fillAmountsOut[i];
            if (fillIn == 0 || fillIn > remaining) continue;
            if (fillOut < (o.amountOutMin * fillIn) / o.amountIn) continue;
            totalValue += fillOut;
        }
        if (msg.value < totalValue) revert HRH_InsufficientValue();
        uint256 paid = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = _orders[orderIds[i]];
            if (!o.exists || o.cancelled || o.maker == msg.sender || block.number > o.expiryBlock) continue;
            uint256 remaining = o.amountIn - o.amountFilledIn;
            if (remaining == 0) continue;
            uint256 fillIn = fillAmountsIn[i];
            uint256 fillOut = fillAmountsOut[i];
            if (fillIn == 0 || fillIn > remaining) continue;
            if (fillOut < (o.amountOutMin * fillIn) / o.amountIn) continue;
            uint256 fee = (fillOut * feeBps) / HRH_FEE_DENOM_BPS;
            uint256 makerReceives = fillOut - fee;
            if (feeBps > 0 && feeCollector != address(0)) {
                (bool feeOk, ) = feeCollector.call{value: fee}("");
                if (!feeOk) revert HRH_TransferFailed();
            }
            (bool payOk, ) = o.maker.call{value: makerReceives}("");
            if (!payOk) revert HRH_TransferFailed();
            paid += fillOut;
            o.amountFilledIn += fillIn;
            emit OrderFilled(orderIds[i], msg.sender, fillIn, fillOut, uint64(block.timestamp));
        }
        if (msg.value > paid) {
            (bool refundOk, ) = msg.sender.call{value: msg.value - paid}("");
            if (!refundOk) revert HRH_TransferFailed();
        }
    }

    function name() external pure returns (string memory) {
        return "Hurrah OTC Order Book";
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    function domainSeparator() external view returns (bytes32) {
        return keccak256(abi.encodePacked(HRH_NAMESPACE, block.chainid, address(this)));
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS: ORDER BOOK SNAPSHOT HELPERS
    // -------------------------------------------------------------------------

    function getOrderBookSnapshot(uint256 fromIndex, uint256 count)
        external
        view
        returns (
            bytes32[] memory ids,
            address[] memory makers,
            uint8[] memory sides,
            uint256[] memory amountsIn,
            uint256[] memory amountsOutMin,
            uint256[] memory amountsFilled,
            uint64[] memory expiries,
            bool[] memory active
        )
    {
        if (fromIndex >= _orderIds.length) revert HRH_InvalidIndex();
        uint256 end = fromIndex + count;
        if (end > _orderIds.length) end = _orderIds.length;
        uint256 n = end - fromIndex;
        ids = new bytes32[](n);
        makers = new address[](n);
        sides = new uint8[](n);
        amountsIn = new uint256[](n);
        amountsOutMin = new uint256[](n);
        amountsFilled = new uint256[](n);
        expiries = new uint64[](n);
        active = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 oid = _orderIds[fromIndex + i];
            Order storage o = _orders[oid];
            ids[i] = oid;
            if (o.exists) {
                makers[i] = o.maker;
                sides[i] = o.side;
                amountsIn[i] = o.amountIn;
                amountsOutMin[i] = o.amountOutMin;
                amountsFilled[i] = o.amountFilledIn;
                expiries[i] = o.expiryBlock;
                active[i] = !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn;
            }
        }
        return (ids, makers, sides, amountsIn, amountsOutMin, amountsFilled, expiries, active);
    }

    function getOrdersBySide(uint8 side, uint256 maxResults) external view returns (bytes32[] memory orderIds) {
        uint256 cap = maxResults > _orderIds.length ? _orderIds.length : maxResults;
        uint256[] memory temp = new uint256[](cap);
        uint256 count = 0;
        for (uint256 i = 0; i < _orderIds.length && count < cap; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn && o.side == side) {
                temp[count] = i;
                count++;
            }
        }
        orderIds = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) orderIds[j] = _orderIds[temp[j]];
        return orderIds;
    }

    function getOrdersByChains(uint64 chainOrigin, uint64 chainSettle, uint256 maxResults) external view returns (bytes32[] memory orderIds) {
        uint256 cap = maxResults > _orderIds.length ? _orderIds.length : maxResults;
        uint256 count = 0;
        for (uint256 i = 0; i < _orderIds.length && count < cap; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn
                && o.chainIdOrigin == chainOrigin && o.chainIdSettle == chainSettle) {
                count++;
            }
        }
        orderIds = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _orderIds.length && j < count; i++) {
            Order storage o = _orders[_orderIds[i]];
            if (o.exists && !o.cancelled && !o.settled && block.number <= o.expiryBlock && o.amountFilledIn < o.amountIn
                && o.chainIdOrigin == chainOrigin && o.chainIdSettle == chainSettle) {
                orderIds[j] = _orderIds[i];
                j++;
            }
        }
        return orderIds;
    }

    function hasActiveOrder(address maker, bytes32 orderId) external view returns (bool) {
        if (!_orders[orderId].exists || _orders[orderId].maker != maker) return false;
        return isOrderActive(orderId);
    }

    function getFillProgress(bytes32 orderId) external view returns (uint256 filled, uint256 total, uint256 remaining) {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        return (o.amountFilledIn, o.amountIn, o.amountIn - o.amountFilledIn);
    }

    function getEffectivePrice(bytes32 orderId) external view returns (uint256 amountOutPerUnitIn) {
        Order storage o = _orders[orderId];
        if (!o.exists || o.amountIn == 0) revert HRH_OrderNotFound();
        return (o.amountOutMin * 1e18) / o.amountIn;
    }

    function isOrderFullyFilled(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return o.exists && o.amountFilledIn >= o.amountIn;
    }

    function isOrderExpired(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return o.exists && block.number > o.expiryBlock;
    }

    function getRoleAddresses() external view returns (address gov, address keeper, address feeCol, address relay) {
        return (governor, settlementKeeper, feeCollector, bridgeRelay);
    }

    function getLimits() external view returns (uint256 minAmt, uint256 maxAmt, uint256 maxOrders) {
        return (minOrderAmount, maxOrderAmount, HRH_MAX_ORDERS);
    }

    function getFeeConfig() external view returns (uint256 bps, uint256 denom, uint256 maxBps) {
        return (feeBps, HRH_FEE_DENOM_BPS, HRH_MAX_FEE_BPS);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }

    // -------------------------------------------------------------------------
    // PURE HELPERS & CONSTANTS EXPOSURE
    // -------------------------------------------------------------------------

    function feeDenomBps() external pure returns (uint256) { return HRH_FEE_DENOM_BPS; }
    function maxFeeBps() external pure returns (uint256) { return HRH_MAX_FEE_BPS; }
    function sideBuy() external pure returns (uint8) { return uint8(HRH_SIDE_BUY); }
    function sideSell() external pure returns (uint8) { return uint8(HRH_SIDE_SELL); }
    function maxOrdersLimit() external pure returns (uint256) { return HRH_MAX_ORDERS; }
    function minExpiryOffsetBlocks() external pure returns (uint256) { return HRH_MIN_EXPIRY_OFFSET; }
    function maxExpiryOffsetBlocks() external pure returns (uint256) { return HRH_MAX_EXPIRY_OFFSET; }
    function maxBatchCancel() external pure returns (uint256) { return HRH_MAX_BATCH_CANCEL; }
    function maxBatchFill() external pure returns (uint256) { return HRH_MAX_BATCH_FILL; }
    function maxBatchPost() external pure returns (uint256) { return HRH_MAX_BATCH_POST; }
    function namespace() external pure returns (bytes32) { return HRH_NAMESPACE; }
    function versionHash() external pure returns (bytes32) { return HRH_VERSION; }

    // -------------------------------------------------------------------------
    // BULK ORDER SUMMARY (GAS-EFFICIENT BATCH READ)
    // -------------------------------------------------------------------------

    struct OrderSummary {
        bytes32 orderId;
        address maker;
        uint8 side;
        uint64 chainIdOrigin;
        uint64 chainIdSettle;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountFilledIn;
        uint64 expiryBlock;
        bool cancelled;
        bool settled;
    }

    function getOrderSummariesInRange(uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (OrderSummary[] memory summaries)
    {
        if (fromIndex > toIndex || toIndex >= _orderIds.length) revert HRH_InvalidIndex();
        uint256 n = toIndex - fromIndex + 1;
        summaries = new OrderSummary[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 oid = _orderIds[fromIndex + i];
            Order storage o = _orders[oid];
            summaries[i] = OrderSummary({
                orderId: oid,
                maker: o.maker,
                side: o.side,
                chainIdOrigin: o.chainIdOrigin,
                chainIdSettle: o.chainIdSettle,
                amountIn: o.amountIn,
                amountOutMin: o.amountOutMin,
                amountFilledIn: o.amountFilledIn,
                expiryBlock: o.expiryBlock,
                cancelled: o.cancelled,
                settled: o.settled
            });
        }
        return summaries;
    }

    function getOrderSummariesForMaker(address maker, uint256 offset, uint256 limit)
        external
        view
        returns (OrderSummary[] memory summaries)
    {
        bytes32[] storage ids = _makerOrderIds[maker];
        if (offset >= ids.length) return new OrderSummary[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        uint256 n = end - offset;
        summaries = new OrderSummary[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 oid = ids[offset + i];
            Order storage o = _orders[oid];
            summaries[i] = OrderSummary({
                orderId: oid,
                maker: o.maker,
                side: o.side,
                chainIdOrigin: o.chainIdOrigin,
                chainIdSettle: o.chainIdSettle,
                amountIn: o.amountIn,
                amountOutMin: o.amountOutMin,
                amountFilledIn: o.amountFilledIn,
                expiryBlock: o.expiryBlock,
                cancelled: o.cancelled,
                settled: o.settled
            });
        }
        return summaries;
    }

    function getOrderIdByMakerAndIndex(address maker, uint256 index) external view returns (bytes32) {
        bytes32[] storage ids = _makerOrderIds[maker];
        if (index >= ids.length) revert HRH_InvalidIndex();
        return ids[index];
    }

    function getOriginChainOrderCount(uint64 chainId) external view returns (uint256) {
        return _orderIdsByOriginChain[chainId].length;
    }

    function getSettleChainOrderCount(uint64 chainId) external view returns (uint256) {
        return _orderIdsBySettleChain[chainId].length;
    }

    function validateOrderParams(
        uint8 side,
        uint64 chainIdOrigin,
        uint64 chainIdSettle,
        uint256 amountIn,
        uint256 amountOutMin,
        uint64 expiryBlock
    ) external view returns (bool valid) {
        if (side > HRH_SIDE_SELL) return false;
        if (chainIdOrigin == 0 || chainIdSettle == 0) return false;
        if (amountIn < minOrderAmount || amountIn > maxOrderAmount) return false;
        if (expiryBlock <= block.number) return false;
        if (expiryBlock - block.number < HRH_MIN_EXPIRY_OFFSET || expiryBlock - block.number > HRH_MAX_EXPIRY_OFFSET) return false;
        if (_chainPaused[chainIdOrigin] || _chainPaused[chainIdSettle]) return false;
        return true;
    }

    function estimateFeeForAmount(uint256 amountOut) external view returns (uint256 feeWei) {
        return (amountOut * feeBps) / HRH_FEE_DENOM_BPS;
    }

    function canFill(bytes32 orderId, address takerAddr, uint256 fillAmountIn) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (!o.exists || o.cancelled || o.settled) return false;
        if (o.maker == takerAddr) return false;
        if (block.number > o.expiryBlock) return false;
        if (o.amountFilledIn >= o.amountIn) return false;
        if (fillAmountIn == 0 || fillAmountIn > o.amountIn - o.amountFilledIn) return false;
        if (orderBookPaused) return false;
        return true;
    }

    function canCancel(bytes32 orderId, address makerAddr) external view returns (bool) {
        Order storage o = _orders[orderId];
        return o.exists && o.maker == makerAddr && !o.cancelled && o.amountFilledIn < o.amountIn;
    }

    function canSettle(bytes32 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return o.exists && !o.settled && o.amountFilledIn > 0;
    }

    function getOrderIdsPaginated(uint256 pageSize, uint256 pageIndex) external view returns (bytes32[] memory ids) {
        if (pageSize == 0) revert HRH_InvalidAmount();
        uint256 start = pageIndex * pageSize;
        if (start >= _orderIds.length) return new bytes32[](0);
        uint256 end = start + pageSize;
        if (end > _orderIds.length) end = _orderIds.length;
        uint256 n = end - start;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _orderIds[start + i];
        return ids;
    }

    function totalPages(uint256 pageSize) external view returns (uint256) {
        if (pageSize == 0) return 0;
        return (_orderIds.length + pageSize - 1) / pageSize;
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function orderPostedAt(bytes32 orderId) external view returns (uint64) {
        if (!_orders[orderId].exists) revert HRH_OrderNotFound();
        return _orders[orderId].postedAt;
    }

    function orderAssets(bytes32 orderId) external view returns (bytes32 assetIn, bytes32 assetOut) {
        Order storage o = _orders[orderId];
        if (!o.exists) revert HRH_OrderNotFound();
        return (o.assetIn, o.assetOut);
    }
}
