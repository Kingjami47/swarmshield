// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IIntake
/// @notice Intake v2 — Identity MD's on-chain oracle payment contract. The intake has the same
/// address on every chain: 0xa43e6f75ee006411f79ac1c84120606c2330de82. It sells the action id
/// `oracle.request` at version `oracle-1` for 0.5 $IMD: pay with the chain's IMD, the control plane runs the
/// question with its agent panel, and the signed answer is written back as an EIP-712
/// attestation delivered to the callback target.
interface IIntake {
    /// @notice Where the signed answer (and, on v2, failures) are handed to.
    struct Callback {
        address target;
        bytes4 selector;
    }

    /// @notice Pay for an oracle request with a success callback only.
    /// @param action The action id, `bytes32("oracle.request@oracle-1")`.
    /// @param body The oracle body as compact UTF-8 JSON (1 byte to 16 KiB).
    /// @param callback The contract and function the answer is handed to.
    /// @param asset The chain's IMD address.
    /// @param amount At least the price, in atomic units (500000000000000000).
    /// @return requestId The intake's request id (distinct from the oracle request's UUID).
    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);

    /// @notice The same as `request`, plus a failure function on the callback target that fires
    /// when the ask is refused (status 1) or ends without an answer (status 2).
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );

    event FailureHookSet(bytes32 indexed requestId, bytes4 selector);

    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);
}
