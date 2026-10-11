// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {SwarmShieldHook} from "../src/SwarmShieldHook.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title SwarmShieldHookTest
/// @notice 18 tests covering: surcharge (ERC20 + native, static + dynamic pools), LP fee
/// override (20000 -> 3000), verdict flow with real EIP-712 signatures, negative verdicts,
/// expiry, replay/signer/panel/non-bool guards, failure hook, permissionless retry, rug shield
/// caps + rollover + decay, flush to burn, invalid pools, and only-PoolManager entry guards.
contract SwarmShieldHookTest is Test, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    Currency constant NATIVE = CurrencyLibrary.ADDRESS_ZERO;
    uint24 constant FEE_DYNAMIC = LPFeeLibrary.DYNAMIC_FEE_FLAG; // 0x800000
    uint24 constant FEE_STATIC = 3000; // a normal policy fee
    uint160 constant HOOK_FLAGS = uint160(0x288);
    uint160 constant ALL_HOOKS_MASK = uint160((1 << 14) - 1);

    uint256 constant ORACLE_PK = 0xA11CE;
    address constant INTAKE_ADDRESS = address(0xA17A1);
    address constant FLUSH_TO = address(0xdEaD);

    uint256 constant ORACLE_PRICE = 0.5e18;
    uint256 constant INITIAL_BALANCE = 1e30;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    uint128 constant LIQUIDITY = 1e21;

    PoolManager manager;
    MockERC20 tokenA; // the launch token the hook guards
    MockERC20 tokenB;
    MockERC20 tokenC;
    MockERC20 imd;
    SwarmShieldHook hook;

    address oracleSignerAddr;

    // The fixed oracle question (compact JSON; the hook only ever keccak-hashes it).
    string constant BODY_JSON =
        '{"v":1,"question":"Do the IMD launch registry and the X account @SwarmShieldIMD identify the same deployer wallet, with no impersonation evidence?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":7,"quorum":5}';

    PoolKey keyDyn; // tokenA/tokenB, dynamic fee, hook
    PoolKey keyStatic; // tokenA/tokenB, static fee, hook
    PoolKey keyNative; // NATIVE/tokenA, dynamic fee, hook
    PoolKey keyBad; // tokenB/tokenC, dynamic fee, hook -> INVALID_POOL

    uint256 internal _intakeCounter;

    enum Action {
        AddLiquidity,
        Swap
    }

    struct CallbackData {
        PoolKey key;
        Action action;
        bool zeroForOne;
        int256 amount;
    }

    function setUp() public {
        manager = new PoolManager(address(this));
        tokenA = new MockERC20("SwarmShield", "SHIELD");
        tokenB = new MockERC20("Token B", "TB");
        tokenC = new MockERC20("Token C", "TC");
        imd = new MockERC20("Identity MD", "IMD");
        oracleSignerAddr = vm.addr(ORACLE_PK);

        bytes32 salt = _mineHookSalt();
        hook = new SwarmShieldHook{salt: salt}(
            manager,
            address(tokenA),
            IIntake(INTAKE_ADDRESS),
            IERC20Minimal(address(imd)),
            ORACLE_PRICE,
            oracleSignerAddr,
            bytes(BODY_JSON),
            FLUSH_TO,
            100, // surchargeBps: 1%
            20000, // protectedLpFee: 2%
            3000, // trustedLpFee: 0.30%
            1000, // rugShieldBps: 10%
            30 days // verdictTtl
        );

        tokenA.mint(address(this), INITIAL_BALANCE);
        tokenB.mint(address(this), INITIAL_BALANCE);
        tokenC.mint(address(this), INITIAL_BALANCE);
        imd.mint(address(this), INITIAL_BALANCE);
        vm.deal(address(this), INITIAL_BALANCE);

        (Currency c0, Currency c1) = _sort(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        keyDyn = PoolKey(c0, c1, FEE_DYNAMIC, 60, hook);
        keyStatic = PoolKey(c0, c1, FEE_STATIC, 60, hook);
        keyNative = PoolKey(NATIVE, Currency.wrap(address(tokenA)), FEE_DYNAMIC, 60, hook);
        (Currency b0, Currency b1) = _sort(Currency.wrap(address(tokenB)), Currency.wrap(address(tokenC)));
        keyBad = PoolKey(b0, b1, FEE_DYNAMIC, 60, hook);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        manager.initialize(keyDyn, sqrtPrice);
        manager.initialize(keyStatic, sqrtPrice);
        manager.initialize(keyNative, sqrtPrice);
        manager.initialize(keyBad, sqrtPrice);

        _addLiquidity(keyDyn, LIQUIDITY);
        _addLiquidity(keyStatic, LIQUIDITY);
        _addLiquidity(keyNative, LIQUIDITY);
    }

    // ------------------------------------------------------------------ //
    //                               Tests                                //
    // ------------------------------------------------------------------ //

    function test_HookAddressHasRequiredFlags() public view {
        assertEq(uint160(address(hook)) & ALL_HOOKS_MASK, HOOK_FLAGS, "flags");
        assertEq(hook.FLAGS(), HOOK_FLAGS, "constant");
        // exactly the three permissions we need, nothing more
        assertEq(uint160(address(hook)) & ALL_HOOKS_MASK, uint160((1 << 9) | (1 << 7) | (1 << 3)), "layout");
    }

    function test_UnverifiedSwap_TakesSurcharge_DynamicPool() public {
        assertFalse(hook.isTrusted(), "starts trusted");
        uint256 hookBefore = _guardedBalance(address(hook), keyDyn);
        uint24 fee = _doSwap(keyDyn, true, -1e18);
        assertEq(fee, 20000, "lp fee should be the protected override");
        assertEq(_guardedBalance(address(hook), keyDyn) - hookBefore, 1e16, "surcharge should be 1%");
    }

    function test_StaticPool_OverrideIgnored_SurchargeOnly() public {
        uint256 hookBefore = _guardedBalance(address(hook), keyStatic);
        uint24 fee = _doSwap(keyStatic, true, -1e18);
        assertEq(fee, FEE_STATIC, "static pool must keep its policy fee");
        assertEq(_guardedBalance(address(hook), keyStatic) - hookBefore, 1e16, "surcharge still applies");
    }

    function test_NativeSurcharge_ExactIn() public {
        uint256 hookBefore = address(hook).balance;
        uint24 fee = _doSwap(keyNative, true, -1e18); // exactIn NATIVE -> tokenA
        assertEq(fee, 20000, "protected fee on the native pool");
        assertEq(address(hook).balance - hookBefore, 1e16, "native surcharge 1%");
    }

    function test_TrustedSwap_NoSurcharge_BetterFee() public {
        _grantTrust(true);
        assertTrue(hook.isTrusted(), "should be trusted");
        uint256 hookBefore = _guardedBalance(address(hook), keyDyn);
        uint24 fee = _doSwap(keyDyn, true, -1e18);
        assertEq(fee, 3000, "trusted lp fee");
        assertEq(_guardedBalance(address(hook), keyDyn) - hookBefore, 0, "no surcharge when trusted");
    }

    function test_Verify_PullsHalfIMDFromPayer() public {
        _mockIntakeRequest(bytes32(uint256(1)));
        imd.approve(address(hook), ORACLE_PRICE);
        uint256 before = imd.balanceOf(address(this));
        bytes32 id = hook.verify();
        assertEq(imd.balanceOf(address(this)), before - ORACLE_PRICE, "pays 0.5 IMD");
        assertTrue(hook.pending(id), "request pending");
        assertFalse(hook.isTrusted(), "not yet trusted");
    }

    function test_Verdict_FlipsTrust_ThenExpires() public {
        _grantTrust(true);
        assertTrue(hook.isTrusted(), "trusted after verdict");
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(hook.isTrusted(), "expired verdict -> protected again");
    }

    function test_NegativeVerdict_StaysProtected() public {
        (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig) = _runVerify();
        a.answer = abi.encode(false);
        sig = _signAs(a, ORACLE_PK); // re-sign the mutated message
        vm.prank(INTAKE_ADDRESS);
        hook.onOracleResult(intakeId, a, sig);
        assertFalse(hook.isTrusted(), "false verdict must not grant trust");

        uint256 hookBefore = _guardedBalance(address(hook), keyDyn);
        _doSwap(keyDyn, true, -1e18);
        assertEq(_guardedBalance(address(hook), keyDyn) - hookBefore, 1e16, "still surcharged");
    }

    function test_Submit_PermissionlessRetry() public {
        (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig) = _runVerify();
        hook.submit(intakeId, a, sig); // anyone, no prank
        assertTrue(hook.isTrusted(), "submit grants trust");
    }

    function test_FailureHook_ClearsPending() public {
        _mockIntakeRequest(bytes32(uint256(7)));
        imd.approve(address(hook), ORACLE_PRICE);
        bytes32 id = hook.verify();
        assertTrue(hook.pending(id), "pending");
        vm.prank(INTAKE_ADDRESS);
        hook.onOracleFailure(id, 2, bytes32("disagreed"), 0, 0, "");
        assertFalse(hook.pending(id), "cleared");
        assertEq(hook.lastFailure(), bytes32("disagreed"), "reason recorded");
        assertFalse(hook.isTrusted(), "failures never grant trust");
    }

    function test_Replay_Reverts() public {
        (, OracleAttestation.Attestation memory a, bytes memory sig) = _grantTrust(true);
        // a second pending request delivering the SAME oracle attestation -> replay
        _mockIntakeRequest(bytes32(uint256(2)));
        imd.approve(address(hook), ORACLE_PRICE);
        bytes32 id2 = hook.verify();
        vm.prank(INTAKE_ADDRESS);
        vm.expectRevert(bytes("REPLAY"));
        hook.onOracleResult(id2, a, sig);
    }

    function test_BadSignature_Reverts() public {
        (bytes32 intakeId, OracleAttestation.Attestation memory a,) = _runVerify();
        bytes memory badSig = _signAs(a, 0xBAD); // right message, wrong signer
        vm.prank(INTAKE_ADDRESS);
        vm.expectRevert(bytes("BAD_ORACLE_SIGNATURE"));
        hook.onOracleResult(intakeId, a, badSig);
        assertFalse(hook.isTrusted(), "no trust on bad signature");
    }

    function test_WeakPanel_Reverts() public {
        (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig) = _runVerify();
        a.quorum = a.agreed + 1; // panel too weak (signature now stale, but quorum reverts first)
        vm.prank(INTAKE_ADDRESS);
        vm.expectRevert(bytes("WEAK_PANEL"));
        hook.onOracleResult(intakeId, a, sig);
    }

    function test_NonBoolAnswer_Reverts() public {
        (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig) = _runVerify();
        a.answerType = 3; // uint256
        a.answer = abi.encode(uint256(1));
        vm.prank(INTAKE_ADDRESS);
        vm.expectRevert(bytes("NOT_BOOL"));
        hook.onOracleResult(intakeId, a, sig);
    }

    function test_InvalidPool_SwapReverts() public {
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(address(manager));
        vm.expectRevert(bytes("INVALID_POOL"));
        hook.beforeSwap(address(this), keyBad, sp, "");
    }

    function test_OnlyPoolManager_CanCallHookEntries() public {
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(bytes("ONLY_POOL_MANAGER"));
        hook.beforeSwap(address(this), keyDyn, sp, "");

        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: -1,
            salt: bytes32(0)
        });
        vm.expectRevert(bytes("ONLY_POOL_MANAGER"));
        hook.beforeRemoveLiquidity(address(this), keyDyn, mlp, "");
    }

    function test_RugShield_CapsDailyRemoval() public {
        uint256 liquidity = uint256(LIQUIDITY);
        // a removal of 10% + 1 wei of liquidity must revert (called directly, as the manager)
        _expectRugShieldRemove(liquidity / 10 + 1);
        // exactly 10% passes, through the real pool flow
        _removeLiquidity(keyDyn, liquidity / 10);
        // the bucket is cumulative: nothing more may leave in the same UTC day
        _expectRugShieldRemove(liquidity / 100);
        // next bucket: the cap decays geometrically -> 10% of what is left (0.9L)
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _removeLiquidity(keyDyn, liquidity / 100);
    }

    function test_Flush_SendsToBurn() public {
        _doSwap(keyDyn, true, -1e18);
        uint256 stale = _guardedBalance(address(hook), keyDyn);
        assertGt(stale, 0, "nothing to flush");
        Currency c = _guardedCurrency(keyDyn);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwarmShieldHook.Flushed(c, stale, FLUSH_TO);
        hook.flush(c);
        assertEq(_guardedBalance(address(hook), keyDyn), 0, "hook drained");
        assertEq(_guardedBalance(FLUSH_TO, keyDyn), stale, "burn address received");
    }






    // ------------------------------------------------------------------ //
    //                           Test plumbing                            //
    // ------------------------------------------------------------------ //

    /// @notice verify() -> attestation ready to deliver (true answer, signed by the real key).
    function _runVerify()
        internal
        returns (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig)
    {
        intakeId = _mockIntakeRequest(bytes32(uint256(++_intakeCounter + 100)));
        imd.approve(address(hook), ORACLE_PRICE);
        hook.verify();
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode(intakeId)), // oracle UUID, distinct on purpose
            chainId: block.chainid,
            questionHash: keccak256(bytes(BODY_JSON)),
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 0,
            toBlock: 1,
            blockHash: bytes32(0),
            panelJobId: bytes32(0),
            panelSize: 7,
            quorum: 5,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        sig = _signAs(a, ORACLE_PK);
    }

    function _grantTrust(bool verdict)
        internal
        returns (bytes32 intakeId, OracleAttestation.Attestation memory a, bytes memory sig)
    {
        (intakeId, a, sig) = _runVerify();
        a.answer = abi.encode(verdict);
        sig = _signAs(a, ORACLE_PK); // re-sign the mutated message
        vm.prank(INTAKE_ADDRESS);
        hook.onOracleResult(intakeId, a, sig);
        assertEq(hook.isTrusted(), verdict, "verdict not applied");
    }

    function _signAs(OracleAttestation.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hook.domainSeparatorV2(), hook.hashAttestation(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mockIntakeRequest(bytes32 requestId) internal returns (bytes32) {
        vm.mockCall(INTAKE_ADDRESS, abi.encodePacked(IIntake.requestWithFailure.selector), abi.encode(requestId));
        return requestId;
    }

    // --- pool ops through the PoolManager lock --- //

    function _addLiquidity(PoolKey memory key, uint128 liquidity) internal {
        manager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    action: Action.AddLiquidity,
                    zeroForOne: true,
                    amount: int256(uint256(liquidity))
                })
            )
        );
    }

    function _removeLiquidity(PoolKey memory key, uint256 liquidity) internal {
        manager.unlock(
            abi.encode(
                CallbackData({key: key, action: Action.AddLiquidity, zeroForOne: true, amount: -int256(liquidity)})
            )
        );
    }

    function _expectRugShieldRemove(uint256 liquidity) internal {
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: -int256(liquidity),
            salt: bytes32(0)
        });
        vm.prank(address(manager));
        vm.expectRevert(bytes("RUG_SHIELD"));
        hook.beforeRemoveLiquidity(address(this), keyDyn, mlp, "");
    }

    function _doSwap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        vm.recordLogs();
        manager.unlock(
            abi.encode(CallbackData({key: key, action: Action.Swap, zeroForOne: zeroForOne, amount: amountSpecified}))
        );
        fee = _lastSwapFee();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        CallbackData memory cd = abi.decode(data, (CallbackData));
        if (cd.action == Action.AddLiquidity) {
            manager.modifyLiquidity(
                cd.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: cd.amount,
                    salt: bytes32(0)
                }),
                ""
            );
        } else {
            uint160 limit = cd.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            manager.swap(
                cd.key,
                IPoolManager.SwapParams({
                    zeroForOne: cd.zeroForOne,
                    amountSpecified: cd.amount,
                    sqrtPriceLimitX96: limit
                }),
                ""
            );
        }
        _settle(cd.key.currency0);
        _settle(cd.key.currency1);
        return "";
    }

    function _settle(Currency currency) internal {
        int256 delta = TransientStateLibrary.currencyDelta(manager, address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }

    // --- helpers --- //

    function _sort(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    /// @notice The side of the pool that holds the guarded token.
    function _guardedCurrency(PoolKey memory key) internal view returns (Currency) {
        return Currency.unwrap(key.currency0) == address(tokenA) ? key.currency0 : key.currency1;
    }

    function _guardedBalance(address who, PoolKey memory key) internal view returns (uint256) {
        Currency c = _guardedCurrency(key);
        return c.isAddressZero() ? who.balance : IERC20Minimal(Currency.unwrap(c)).balanceOf(who);
    }

    function _mineHookSalt() internal view returns (bytes32 salt) {
        bytes memory initCode = abi.encodePacked(
            type(SwarmShieldHook).creationCode,
            abi.encode(
                manager,
                address(tokenA),
                IIntake(INTAKE_ADDRESS),
                IERC20Minimal(address(imd)),
                ORACLE_PRICE,
                oracleSignerAddr,
                bytes(BODY_JSON),
                FLUSH_TO,
                uint24(100),
                uint24(20000),
                uint24(3000),
                uint24(1000),
                uint40(30 days)
            )
        );
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (uint160(predicted) & ALL_HOOKS_MASK == HOOK_FLAGS) return bytes32(i);
        }
        revert("salt not found");
    }

    /// @notice Reads the lp fee the pool actually used, from the Swap event.
    function _lastSwapFee() internal returns (uint24 fee) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i - 1].emitter == address(manager) && entries[i - 1].topics[0] == swapTopic) {
                (, , , , , fee) = abi.decode(entries[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no swap found");
    }

    receive() external payable {}
}
