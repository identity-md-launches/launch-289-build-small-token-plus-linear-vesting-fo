// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title LinearVesting
/// @notice Holds ERC-20 tokens for a single beneficiary and releases them linearly over time
///         after an optional cliff.
/// @dev The allocation is whatever the contract holds: `total = balanceOf(this) + released`.
///      Anything transferred to the contract at any time joins the schedule and vests on the
///      same curve. There is no owner, no revoke, no ETH handling, and the parameters are
///      immutable. Rounding is always down, so the beneficiary never receives more than the
///      schedule allows; the remainder is released once the schedule ends.
contract LinearVesting {
    /// @notice Token being vested.
    IERC20 public immutable token;
    /// @notice Sole recipient of released tokens.
    address public immutable beneficiary;
    /// @notice Unix timestamp at which the linear curve begins.
    uint64 public immutable start;
    /// @notice Seconds after `start` before anything can be released.
    uint64 public immutable cliffSeconds;
    /// @notice Total length of the schedule in seconds, measured from `start`.
    uint64 public immutable durationSeconds;

    /// @notice Amount already transferred to the beneficiary.
    uint256 public released;

    event Released(uint256 amount);

    error ZeroAddress();
    error ZeroDuration();
    error CliffExceedsDuration();
    error NothingToRelease();
    error TransferFailed();

    /// @param token_ ERC-20 token to vest (non-zero).
    /// @param beneficiary_ Recipient of released tokens (non-zero).
    /// @param start_ Unix timestamp at which vesting begins.
    /// @param cliffSeconds_ Cliff length in seconds after `start_`; must not exceed `durationSeconds_`.
    /// @param durationSeconds_ Total schedule length in seconds; must be > 0.
    constructor(address token_, address beneficiary_, uint64 start_, uint64 cliffSeconds_, uint64 durationSeconds_) {
        if (token_ == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (durationSeconds_ == 0) revert ZeroDuration();
        if (cliffSeconds_ > durationSeconds_) revert CliffExceedsDuration();

        token = IERC20(token_);
        beneficiary = beneficiary_;
        start = start_;
        cliffSeconds = cliffSeconds_;
        durationSeconds = durationSeconds_;
    }

    /// @notice Timestamp before which nothing vests (`start + cliffSeconds`).
    function cliff() external view returns (uint256) {
        return uint256(start) + cliffSeconds;
    }

    /// @notice Timestamp at which the whole allocation is vested (`start + durationSeconds`).
    function end() external view returns (uint256) {
        return uint256(start) + durationSeconds;
    }

    /// @notice Total allocation: tokens still held plus tokens already released.
    function totalAllocation() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    /// @notice Amount of the allocation that has vested at timestamp `timestamp`.
    /// @dev 0 before the cliff, everything at or after the end, linear (rounded down) in between.
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint256 total = totalAllocation();
        uint256 t = timestamp;
        uint256 s = start;
        if (t < s + cliffSeconds) {
            return 0;
        }
        if (t >= s + durationSeconds) {
            return total;
        }
        return (total * (t - s)) / durationSeconds;
    }

    /// @notice Amount that `release()` would transfer right now.
    function releasable() public view returns (uint256) {
        // casting to 'uint64' is safe because block.timestamp fits in 64 bits for the next ~584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        return vestedAmount(uint64(block.timestamp)) - released;
    }

    /// @notice Transfers every vested-but-unreleased token to the beneficiary. Callable by anyone.
    /// @dev Reverts with `NothingToRelease` if nothing has vested since the last release.
    function release() external {
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        emit Released(amount);
        _safeTransfer(beneficiary, amount);
    }

    /// @dev Tolerates tokens that return nothing, but rejects a `false` return or a revert.
    function _safeTransfer(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
