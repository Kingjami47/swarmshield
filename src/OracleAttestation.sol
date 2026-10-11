// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title OracleAttestation
/// @notice Minimal EIP-712 consumer base for Identity MD oracle answers, domain version 2.
/// The oracle signs answers over the domain
/// `{name: "IdentityMD Oracle", version: "2", chainId, verifyingContract}` where the chain and
/// contract are the consumer's own: every consumer verifies in its own domain, so an attestation
/// signed for one contract is worthless to another.
///
/// Attestation shape (from `GET /oracle/requests/:id/attestation`, primaryType `OracleAttestation`):
/// ```
/// OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,
///   bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,
///   uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
/// ```
/// `answerType`: bool 0, address 1, bytes32 2, uint256 3, address[] 4, bytes32[] 5.
/// `answer` is the `abi.encode` of the value. `requestId` and `panelJobId` are UUIDs as sixteen
/// raw bytes. The attestation's `requestId` is the oracle request's UUID — deliberately distinct
/// from the intake's request id.
abstract contract OracleAttestation {
    struct Attestation {
        bytes32 requestId; // the oracle request's UUID
        uint256 chainId;
        bytes32 questionHash; // keccak-256 of the question body the panel answered
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,"
        "bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,"
        "uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 private constant _NAME_HASH = keccak256(bytes("IdentityMD Oracle"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));

    /// @notice The only attestation signer this consumer accepts. Pin it at construction; the
    /// docs recommend owner settings, but SwarmShield is ownerless by design and the signer is
    /// part of the immutable body of the contract.
    function oracleSigner() public view virtual returns (address);

    /// @notice The EIP-712 domain this consumer verifies attestations in.
    function domainSeparatorV2() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice The EIP-712 struct hash of an attestation.
    function hashAttestation(Attestation calldata a) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _ATTESTATION_TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
    }

    /// @notice Reverts unless `signature` is the oracle signer's EIP-712 signature over `a`,
    /// made in this contract's domain.
    function _verifyAttestation(Attestation calldata a, bytes calldata signature) internal view {
        require(signature.length == 65, "BAD_SIGNATURE_LENGTH");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorV2(), hashAttestation(a)));

        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 vRaw = uint8(signature[64]);
        uint8 v = vRaw < 27 ? vRaw + 27 : vRaw;

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == oracleSigner(), "BAD_ORACLE_SIGNATURE");
    }
}
