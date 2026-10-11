// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleAttestation} from "./OracleAttestation.sol";

/// @title SwarmShieldHook
/// @notice The swarm-verified liquidity guard — a Uniswap v4 hook that prices Identity MD swarm
/// trust into a pool. Built for the first Identity MD Hackathon (Oct 7–21, 2026).
///
/// The pool it guards starts in *protected* mode and only earns *trusted* terms when a quorum of
/// independent IMD agents — paid through the Identity MD oracle, verified with an EIP-712
/// attestation — confirms the project is authentic and not another copycat:
///
/// 1. Trust-priced LP fee — on dynamic-fee pools the hook overrides the LP fee per swap:
///    `protectedLpFee` (2%) while unverified, `trustedLpFee` (0.30%) once trusted. Static-fee
///    pools ignore the override and keep their policy fee.
/// 2. Protection surcharge — while unverified, every swap pays `surchargeBps` (1%) of the
///    specified currency to the hook. The hook takes it immediately with `poolManager.take`
///    inside the swap's lock, clamped to the PoolManager's real balance so a swap can never
///    brick. Anyone can `flush` the accumulated surcharges to `flushTo` (0xdEaD by default):
///    an unverified pool bleeds to the burn address.
/// 3. Rug shield — liquidity removals are capped at `rugShieldBps` (10%) of the pool's current
///    in-range liquidity per UTC-day bucket. The cap decays geometrically as liquidity leaves:
///    every day you can take at most 10% of what is left. Adds and fee collects
///    (`liquidityDelta == 0`) are never blocked.
///
/// Verification is permissionless: anyone can pay the 0.5 $IMD oracle fee via `verify()`. The
/// question body is fixed at construction; the answer must be a quorum-signed EIP-712
/// attestation delivered by the Intake contract for a request this contract paid for. A verdict
/// holds for `verdictTtl` (30 days) and then the pool falls back to protected terms.
///
/// No owner. No admin. No upgrades. The oracle body is immutable after construction.
contract SwarmShieldHook is IHooks, OracleAttestation {
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Hook permission flags this contract requires in its deployed address:
    /// beforeRemoveLiquidity (1 << 9) | beforeSwap (1 << 7) | beforeSwapReturnDelta (1 << 3).
    uint160 public constant FLAGS = uint160(0x288);
    uint160 private constant _ALL_HOOKS_MASK = uint160((1 << 14) - 1);

    /// @notice The Intake action this hook pays for: `oracle.request` at version `oracle-1`.
    bytes32 public constant ORACLE_ACTION = bytes32("oracle.request@oracle-1");

    /// @notice Attestation answerType for bool answers.
    uint8 public constant BOOL_TYPE = 0;

    /// @notice Uniswap v4 maximum LP fee (100%).
    uint24 public constant MAX_FEE = 1000000;

    IPoolManager public immutable poolManager;
    /// @notice The launch token this hook guards. Exactly one side of the guarded pool.
    address public immutable token;
    /// @notice Intake v2 — same address on every chain.
    IIntake public immutable intake;
    /// @notice The chain's IMD.
    IERC20Minimal public immutable imd;
    /// @notice The only attestation signer accepted (Identity MD's oracle-1 signer).
    address private immutable _signer;
    /// @notice The oracle ask price in IMD atomic units (0.5 $IMD = 0.5e18).
    uint256 public immutable oraclePrice;
    /// @notice The fixed oracle question body, as compact UTF-8 JSON bytes.
    /// (Dynamic types cannot be immutables; it is written once in the constructor and never again.)
    bytes public oracleBody;
    /// @notice keccak256(oracleBody) — every accepted attestation must answer this question.
    bytes32 public immutable questionHash;
    /// @notice Where flushed surcharges go (0xdEaD by default).
    address public immutable flushTo;
    /// @notice Surcharge on swaps while unverified, in bips of the specified amount (100 = 1%).
    uint24 public immutable surchargeBps;
    /// @notice LP fee applied while unverified, on dynamic-fee pools (20000 = 2%).
    uint24 public immutable protectedLpFee;
    /// @notice LP fee applied while trusted, on dynamic-fee pools (3000 = 0.30%).
    uint24 public immutable trustedLpFee;
    /// @notice Max share of current in-range liquidity removable per UTC-day bucket (1000 = 10%).
    uint24 public immutable rugShieldBps;
    /// @notice How long a positive verdict keeps the pool trusted (30 days).
    uint40 public immutable verdictTtl;

    /// @notice Timestamp until which the pool is trusted (0 = never verified).
    uint40 public trustedUntil;

    /// @notice Intake request ids this contract paid for and has not settled.
    mapping(bytes32 => bool) public pending;

    /// @notice Oracle request UUIDs already consumed — replay guard across callback and submit.
    mapping(bytes32 => bool) public settled;

    /// @notice The reason code of the most recent oracle failure (ASCII right-padded).
    bytes32 public lastFailure;

    /// @notice Liquidity removed per UTC-day bucket (rugs are capped per bucket).
    mapping(uint256 => uint256) public removedThisBucket;

    uint256 internal constant _BPS_DENOMINATOR = 10_000;

    event VerificationRequested(bytes32 indexed requestId, address indexed payer);
    event VerificationFailed(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event TrustGranted(uint256 trustedUntil);
    event VerdictRejected(bytes32 indexed oracleRequestId, uint16 agreed, uint16 quorum);
    event SurchargeCollected(Currency indexed currency, uint256 amount);
    event Flushed(Currency indexed currency, uint256 amount, address indexed to);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "ONLY_POOL_MANAGER");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _token,
        IIntake _intake,
        IERC20Minimal _imd,
        uint256 _oraclePrice,
        address _oracleSigner,
        bytes memory _oracleBody,
        address _flushTo,
        uint24 _surchargeBps,
        uint24 _protectedLpFee,
        uint24 _trustedLpFee,
        uint24 _rugShieldBps,
        uint40 _verdictTtl
    ) {
        require(address(_poolManager) != address(0), "ZERO_POOL_MANAGER");
        require(_token != address(0), "ZERO_TOKEN");
        require(address(_intake) != address(0), "ZERO_INTAKE");
        require(address(_imd) != address(0), "ZERO_IMD");
        require(_oraclePrice != 0, "ZERO_PRICE");
        require(_oracleSigner != address(0), "ZERO_SIGNER");
        require(_oracleBody.length != 0, "EMPTY_BODY");
        require(_flushTo != address(0), "ZERO_FLUSH_TO");
        require(_protectedLpFee <= MAX_FEE && _trustedLpFee <= MAX_FEE, "FEE_OVER_MAX");
        require(_trustedLpFee <= _protectedLpFee, "TRUSTED_MORE_EXPENSIVE");
        require(_rugShieldBps <= _BPS_DENOMINATOR, "RUG_SHIELD_OVER_100");
        // A hook mined without the exact permission flags would silently never run its callbacks.
        require(uint160(address(this)) & _ALL_HOOKS_MASK == FLAGS, "WRONG_HOOK_FLAGS");

        poolManager = _poolManager;
        _signer = _oracleSigner;
        oracleBody = _oracleBody;
        token = _token;
        intake = _intake;
        imd = _imd;
        oraclePrice = _oraclePrice;
        questionHash = keccak256(_oracleBody);
        flushTo = _flushTo;
        surchargeBps = _surchargeBps;
        protectedLpFee = _protectedLpFee;
        trustedLpFee = _trustedLpFee;
        rugShieldBps = _rugShieldBps;
        verdictTtl = _verdictTtl;
    }

    /// @notice The only attestation signer accepted (Identity MD's oracle-1 signer).
    function oracleSigner() public view override returns (address) {
        return _signer;
    }

    /// @notice True while a positive verdict is in force.
    function isTrusted() public view returns (bool) {
        return block.timestamp < trustedUntil;
    }

    // ------------------------------------------------------------------ //
    //                          Uniswap v4 hooks                          //
    // ------------------------------------------------------------------ //

    /// @inheritdoc IHooks
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        _validatePool(key); // binds/refuses the guarded pool

        bool trusted = block.timestamp < trustedUntil;

        // 1. Trust-priced LP fee. Only honored by v4-core when the pool has a dynamic fee and
        //    the override flag (0x400000) is set; static-fee pools keep their policy fee.
        uint24 lpFee = (trusted ? trustedLpFee : protectedLpFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // 2. Protection surcharge on the specified currency while unverified.
        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (!trusted && surchargeBps != 0) {
            Currency specified = params.zeroForOne ? key.currency0 : key.currency1;
            // amountSpecified < 0 is exactIn; the surcharge basis is the specified amount.
            uint256 base = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 surcharge = FullMath.mulDiv(base, surchargeBps, _BPS_DENOMINATOR);

            // Clamp to what the PoolManager really holds and to int128: a swap can never brick.
            uint256 pmBalance = _poolManagerBalance(specified);
            if (surcharge > pmBalance) surcharge = pmBalance;
            if (surcharge > uint256(uint128(type(int128).max))) surcharge = uint256(uint128(type(int128).max));

            if (surcharge != 0) {
                // Take now, inside the swap's lock; the positive specified delta charges the
                // swapper for exactly what was taken, so all deltas settle within the lock.
                poolManager.take(specified, address(this), surcharge);
                delta = toBeforeSwapDelta(surcharge.toInt128(), 0);
                emit SurchargeCollected(specified, surcharge);
            }
        }

        return (IHooks.beforeSwap.selector, delta, lpFee);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId id = _validatePool(key); // binds/refuses the guarded pool

        // Fee collects pass untouched; only principal removals are capped.
        if (params.liquidityDelta != 0) {
            uint256 bucket = block.timestamp / 1 days;
            uint256 currentLiquidity = uint256(poolManager.getLiquidity(id));
            uint256 cap = FullMath.mulDiv(currentLiquidity, rugShieldBps, _BPS_DENOMINATOR);
            uint256 removing = uint256(-params.liquidityDelta);
            uint256 removed = removedThisBucket[bucket] + removing;
            require(removed <= cap, "RUG_SHIELD");
            removedThisBucket[bucket] = removed;
        }

        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ------------------------------------------------------------------ //
    //                        Swarm verification                          //
    // ------------------------------------------------------------------ //

    /// @notice Ask the swarm. Permissionless: anyone can pay the 0.5 $IMD oracle fee and trigger
    /// the verification question that is fixed at construction.
    /// @return requestId The Intake request id the answer will arrive under.
    function verify() external returns (bytes32 requestId) {
        // Pull the fee from the payer, then let the intake pull exactly the price from us.
        IERC20Minimal(imd).transferFrom(msg.sender, address(this), oraclePrice);
        IERC20Minimal(imd).approve(address(intake), oraclePrice);

        requestId = intake.requestWithFailure(
            ORACLE_ACTION,
            oracleBody,
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onOracleFailure.selector,
            address(imd),
            oraclePrice
        );
        pending[requestId] = true;
        emit VerificationRequested(requestId, msg.sender);
    }

    /// @notice Intake callback for a signed answer. Only the intake, only for a request this
    /// contract paid for, only for the pinned question, only with a quorum.
    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature) external {
        require(msg.sender == address(intake), "ONLY_INTAKE");
        require(pending[requestId], "NOT_PENDING");
        delete pending[requestId];
        _applyVerdict(a, signature);
    }

    /// @notice Intake failure hook. Unsigned by design: it only clears the pending request and
    /// records the reason — never grants or revokes trust on its own.
    function onOracleFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
    {
        require(msg.sender == address(intake), "ONLY_INTAKE");
        require(pending[requestId], "NOT_PENDING");
        delete pending[requestId];
        lastFailure = reason;
        emit VerificationFailed(requestId, status, reason);
    }

    /// @notice Permissionless retry: if the intake's delivery attempt reverted (200k gas cap),
    /// anyone can hand the same attestation over again.
    function submit(bytes32 requestId, Attestation calldata a, bytes calldata signature) external {
        require(pending[requestId], "NOT_PENDING");
        delete pending[requestId];
        _applyVerdict(a, signature);
    }

    /// @notice Shared verdict application: replay-guarded, question-pinned, quorum-checked,
    /// signature-verified, bool-only. A `true` answer grants trusted terms for `verdictTtl`; a
    /// `false` answer is recorded and the pool stays protected.
    function _applyVerdict(Attestation calldata a, bytes calldata signature) internal {
        require(!settled[a.requestId], "REPLAY");
        require(a.agreed >= a.quorum, "WEAK_PANEL");
        require(a.questionHash == questionHash, "WRONG_QUESTION");
        require(a.answerType == BOOL_TYPE, "NOT_BOOL");
        require(a.expiresAt >= block.timestamp, "STALE_ATTESTATION");

        _verifyAttestation(a, signature);
        settled[a.requestId] = true;

        bool verdict = abi.decode(a.answer, (bool));
        if (verdict) {
            trustedUntil = uint40(block.timestamp) + verdictTtl;
            emit TrustGranted(uint256(trustedUntil));
        } else {
            emit VerdictRejected(a.requestId, a.agreed, a.quorum);
        }
    }

    // ------------------------------------------------------------------ //
    //                            Surcharge sink                          //
    // ------------------------------------------------------------------ //

    /// @notice Permissionless: forward the hook's entire balance of `currency` to `flushTo`.
    /// An unverified pool bleeds to the burn address.
    function flush(Currency currency) external {
        uint256 amount = currency.balanceOfSelf();
        require(amount != 0, "NOTHING_TO_FLUSH");
        currency.transfer(flushTo, amount);
        emit Flushed(currency, amount, flushTo);
    }

    // ------------------------------------------------------------------ //
    //      Unflagged callbacks: required by IHooks, never called by v4    //
    // ------------------------------------------------------------------ //

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ------------------------------------------------------------------ //
    //                               Internals                            //
    // ------------------------------------------------------------------ //

    /// @notice Refuse any pool that does not have the guarded token on exactly one side.
    function _validatePool(PoolKey calldata key) internal view returns (PoolId id) {
        id = key.toId();
        bool tokenIs0 = key.currency0 == Currency.wrap(token);
        bool tokenIs1 = key.currency1 == Currency.wrap(token);
        require(tokenIs0 != tokenIs1, "INVALID_POOL"); // exactly one side is our token
    }

    function _poolManagerBalance(Currency currency) internal view returns (uint256) {
        return currency.balanceOf(address(poolManager));
    }

    /// @notice Native surcharges arrive via poolManager.take (a plain value call).
    receive() external payable {}
}
