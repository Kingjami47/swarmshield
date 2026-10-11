// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwarmShieldHook} from "../src/SwarmShieldHook.sol";

/// @notice Deploys SwarmShieldHook behind the canonical CREATE2 proxy (0x4e59b4…56C), mining a
/// salt so the hook address ends with the permission flags 0x288 (beforeRemoveLiquidity 1<<9 |
/// beforeSwap 1<<7 | beforeSwapReturnDelta 1<<3).
///
/// Required env vars:
///   PRIVATE_KEY        the deploying wallet (needs ETH for gas; the hook is ownerless)
///   TOKEN              the launch token address (substituted for $token in the body)
///   ORACLE_SIGNER      the current oracle-1 signer — fetch
///                      GET https://api.imd.fun/oracle/requests?status=attested&limit=1
///                      and read .requests[0].signer (was 0x5598aa9146215bc13eb26f2c692ad1461fd32982)
/// Optional env vars (defaults = mainnet launch values):
///   POOL_MANAGER       0xe03a1074c86cfedd5c142c4f04f1a1536e203543
///   INTAKE             0xa43e6f75ee006411f79ac1c84120606c2330de82
///   IMD                0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7
///   ORACLE_BODY_PATH   launch/oracle_body.json (compact UTF-8 JSON, $token substituted)
///   FLUSH_TO           0x000000000000000000000000000000000000dEaD
contract DeploySepolia is Script {
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant FLAGS = uint160(0x288);
    uint160 constant ALL_HOOKS_MASK = uint160((1 << 14) - 1);

    function run() external returns (address hook) {
        address poolManager = vm.envOr("POOL_MANAGER", 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        address token = vm.envAddress("TOKEN");
        address intake = vm.envOr("INTAKE", 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        address imd = vm.envOr("IMD", 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        address signer = vm.envAddress("ORACLE_SIGNER");
        string memory bodyPath = vm.envOr("ORACLE_BODY_PATH", string("launch/oracle_body.json"));
        address flushTo = vm.envOr("FLUSH_TO", 0x000000000000000000000000000000000000dEaD);

        bytes memory oracleBody = vm.readFileBinary(bodyPath);
        require(bytes(oracleBody).length != 0, "empty oracle body");

        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager),
            token,
            IIntake(intake),
            IERC20Minimal(imd),
            500000000000000000, // oraclePrice: 0.5 $IMD
            signer,
            oracleBody,
            flushTo,
            uint24(100), // surchargeBps: 1%
            uint24(20000), // protectedLpFee: 2%
            uint24(3000), // trustedLpFee: 0.30%
            uint24(1000), // rugShieldBps: 10% per day
            uint40(30 days) // verdictTtl
        );

        bytes memory initCode = abi.encodePacked(type(SwarmShieldHook).creationCode, ctorArgs);
        bytes32 initHash = keccak256(initCode);

        // Mine the salt: CREATE2 = keccak256(0xff ++ deployer ++ salt ++ initHash)[12:] —
        // Solidity CREATE2 has no extra 0x00 suffix.
        bytes32 salt;
        bool found;
        for (uint256 i; i < 5_000_000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_PROXY, bytes32(i), initHash)))));
            if (uint160(predicted) & ALL_HOOKS_MASK == FLAGS) {
                salt = bytes32(i);
                found = true;
                break;
            }
        }
        require(found, "salt not found in range");
        hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_PROXY, salt, initHash)))));

        vm.startBroadcast();
        (bool ok,) = CREATE2_PROXY.call(abi.encodePacked(salt, initCode));
        require(ok, "create2 deploy failed");
        vm.stopBroadcast();

        require(hook.code.length != 0, "hook not deployed");
        require(uint160(hook) & ALL_HOOKS_MASK == FLAGS, "deployed at wrong flags");
        console2.log("SwarmShieldHook deployed at:", hook);
    }
}
