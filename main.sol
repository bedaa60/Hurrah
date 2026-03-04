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
