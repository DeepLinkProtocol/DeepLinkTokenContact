// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {DLCv2} from "../src/DLCv2.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IDLCv2 {
    function admin() external view returns (address);
    function canUpgradeAddress() external view returns (address);
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function forceTransferCount() external view returns (uint256);
    function disableUpgrade() external view returns (bool);
}

/// @notice Two transactions atomically batched in one script run:
///   1. Deploy the new v2 implementation (no constructor args; initializers disabled).
///   2. From canUpgradeAddress, call proxy.upgradeToAndCall(impl, initializeV2(admin))
///      — single tx that upgrades AND sets initial admin atomically.
///
/// ──────────────────────────── Prerequisites ────────────────────────────
/// The DEPLOYED proxy currently has canUpgradeAddress = address(0). UUPS
/// upgrades will revert until that slot is rewritten. The plan is for the
/// DBC team to use `sudo.setStorage` against the proxy's storage map to set
/// slot 6 to a key we control. After that, this script can run from that
/// key to perform the upgrade.
///
/// Env vars expected:
///   PROXY_ADDRESS  — proxy address (0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe on mainnet)
///   ADMIN_ADDRESS  — wallet allowed to call forceTransfer after upgrade
///                    (STRONGLY RECOMMENDED: a multisig contract, NOT an EOA)
///   PRIVATE_KEY    — canUpgradeAddress private key (deployer + upgrader)
///   DRY_RUN        — optional; if "true", logs what would happen without broadcasting
///
/// Run:
///   forge script script/Upgrade.s.sol:UpgradeScript \
///       --rpc-url $DBC_RPC \
///       --legacy \
///       --broadcast \
///       -vvvv
///
/// ⚠️  `--legacy` is REQUIRED on DBC chain (no EIP-1559 support).
contract UpgradeScript is Script {
    // Mainnet sanity reference — set to expected v1 impl so we don't accidentally
    // upgrade something that isn't DLC. Skip if PROXY_ADDRESS is not mainnet.
    address constant EXPECTED_V1_IMPL = 0xa72e3ebB05131fb6A1DFE6546C0A72c30f424477;
    address constant EXPECTED_MAINNET_PROXY = 0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe;

    bytes32 constant ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        address adminAddress = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        bool    dryRun       = vm.envOr("DRY_RUN", false);
        bool    allowEoaAdmin = vm.envOr("ALLOW_EOA_ADMIN", false);
        uint256 expectedChain = vm.envOr("EXPECTED_CHAIN_ID", uint256(19880818)); // DBC mainnet
        address deployer     = vm.addr(deployerKey);

        console2.log("=== DLC v2 Upgrade ===");
        console2.log("Proxy:             ", proxyAddress);
        console2.log("Deployer/Upgrader: ", deployer);
        console2.log("New admin:         ", adminAddress);
        console2.log("chain.id:          ", block.chainid);
        console2.log("Expected chain.id: ", expectedChain);
        console2.log("Dry run:           ", dryRun);

        // ── Pre-flight checks ───────────────────────────────────────────────
        require(block.chainid == expectedChain, "chain.id mismatch - wrong RPC?");
        require(proxyAddress != address(0),     "PROXY_ADDRESS is zero");
        require(adminAddress != address(0),     "ADMIN_ADDRESS is zero");
        require(deployer     != address(0),     "PRIVATE_KEY derives to zero");
        require(proxyAddress.code.length > 0,   "PROXY_ADDRESS has no code");

        // admin SHOULD be a multisig (contract), not an EOA. forceTransfer
        // has no built-in limit so EOA admin = single point of catastrophic
        // failure. Override with ALLOW_EOA_ADMIN=true (e.g. for testnets).
        if (adminAddress.code.length == 0) {
            console2.log("WARN: ADMIN_ADDRESS is an EOA, not a contract");
            require(
                allowEoaAdmin,
                "refuse EOA admin in production; set ALLOW_EOA_ADMIN=true to override"
            );
        }

        // Confirm we're upgrading the expected impl. Skip this check on testnets
        // or alternate proxies (PROXY_ADDRESS != mainnet).
        if (proxyAddress == EXPECTED_MAINNET_PROXY) {
            address currentImpl = address(uint160(uint256(vm.load(proxyAddress, ERC1967_IMPL_SLOT))));
            require(currentImpl == EXPECTED_V1_IMPL, "current impl is not the expected v1");
        } else {
            address currentImpl = address(uint160(uint256(vm.load(proxyAddress, ERC1967_IMPL_SLOT))));
            console2.log("INFO: non-mainnet proxy, current impl =", currentImpl);
        }

        // Snapshot pre-upgrade state for post-check
        uint256 preTotalSupply = IDLCv2(proxyAddress).totalSupply();
        string  memory preName = IDLCv2(proxyAddress).name();
        string  memory preSymbol = IDLCv2(proxyAddress).symbol();
        require(preTotalSupply > 0, "totalSupply is zero - proxy state suspicious");

        // v1 has a disableContractUpgrade kill switch (slot 7). If anyone
        // ever activated it, _authorizeUpgrade rejects all upgrades.
        require(
            !IDLCv2(proxyAddress).disableUpgrade(),
            "v1 disableUpgrade flag is set - upgrades permanently blocked"
        );

        console2.log("--- Pre-upgrade snapshot ---");
        console2.log("  totalSupply:", preTotalSupply);
        console2.log("  name:       ", preName);
        console2.log("  symbol:     ", preSymbol);

        // Confirm the deployer key actually IS canUpgradeAddress
        address currentUpgrader = IDLCv2(proxyAddress).canUpgradeAddress();
        console2.log("--- Proxy canUpgradeAddress: ", currentUpgrader);
        require(
            currentUpgrader == deployer,
            "deployer is not canUpgradeAddress - run sudo.setStorage on slot 6 first"
        );

        // Deployer needs gas for deploy + upgrade. New DLCv2 ~3-5M, upgrade
        // ~100k. 0.1 ether headroom is generous on DBC. Skip on dry-run.
        if (!dryRun) {
            require(deployer.balance >= 0.05 ether, "deployer balance too low - fund first");
        }

        if (dryRun) {
            console2.log("=== DRY RUN - exiting before broadcast ===");
            return;
        }

        // ── Broadcast: deploy v2 + upgrade + atomic admin set ───────────────
        vm.startBroadcast(deployerKey);

        DLCv2 impl = new DLCv2();
        require(address(impl).code.length > 0, "v2 deployment failed");

        IUUPSUpgradeable(proxyAddress).upgradeToAndCall(
            address(impl),
            abi.encodeWithSelector(DLCv2.initializeV2.selector, adminAddress)
        );

        vm.stopBroadcast();

        // Compute bytecode hash for dbcscan verification cross-check
        bytes32 implHash;
        assembly {
            let size := extcodesize(impl)
            let ptr := mload(0x40)
            extcodecopy(impl, ptr, 0, size)
            implHash := keccak256(ptr, size)
        }
        console2.log("New implementation:", address(impl));
        console2.log("  bytecode size:   ", address(impl).code.length);
        console2.log("  bytecode keccak: ");
        console2.logBytes32(implHash);

        // ── Post-upgrade verification ───────────────────────────────────────
        address postImpl = address(uint160(uint256(vm.load(proxyAddress, ERC1967_IMPL_SLOT))));
        require(postImpl == address(impl), "ERC1967 impl slot did not update - upgrade did NOT persist");

        require(IDLCv2(proxyAddress).admin()              == adminAddress, "admin not set correctly");
        // v1's _authorizeUpgrade CLEARS canUpgradeAddress (slot 6 = 0) before the
        // delegatecall to initializeV2. This is v1's one-time-grant pattern.
        // To upgrade again, MultiSigTimeLock must call setUpgradePermission first.
        require(IDLCv2(proxyAddress).canUpgradeAddress()  == address(0),   "canUpgradeAddress should be 0 (v1 cleared it)");
        require(IDLCv2(proxyAddress).totalSupply()        == preTotalSupply, "totalSupply changed - CRITICAL: state corrupted");
        require(IDLCv2(proxyAddress).decimals()           == 18,           "decimals changed");
        require(IDLCv2(proxyAddress).forceTransferCount() == 0,            "forceTransferCount nonzero - namespace collision?");
        require(keccak256(bytes(IDLCv2(proxyAddress).name()))   == keccak256(bytes(preName)),   "name changed");
        require(keccak256(bytes(IDLCv2(proxyAddress).symbol())) == keccak256(bytes(preSymbol)), "symbol changed");

        console2.log("=== Post-upgrade verified ===");
        console2.log("  impl slot:         ", postImpl);
        console2.log("  admin:             ", IDLCv2(proxyAddress).admin());
        console2.log("  canUpgradeAddress: ", IDLCv2(proxyAddress).canUpgradeAddress(), "(cleared by v1)");
        console2.log("  totalSupply:       ", IDLCv2(proxyAddress).totalSupply(), "(unchanged)");
        console2.log("  decimals:          ", IDLCv2(proxyAddress).decimals());
        console2.log("  forceTransferCount:", IDLCv2(proxyAddress).forceTransferCount());
        console2.log("  name:              ", IDLCv2(proxyAddress).name());
        console2.log("  symbol:            ", IDLCv2(proxyAddress).symbol());
        console2.log("");
        console2.log("NEXT: Admin rotation now requires MultiSigTimeLock (slot 0)");
        console2.log("      to call setAdmin(newAdmin), NOT canUpgradeAddress.");
        console2.log("      Future upgrades require MultiSigTimeLock to call");
        console2.log("      setUpgradePermission(deployer) first.");
        console2.log("=== Done ===");
    }
}

/// @notice Implementation-only deploy. Use this when you want to deploy the
/// new logic contract first (for review on dbcscan) and run the upgrade tx
/// manually later, possibly via a multisig.
contract DeployImplementation is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        DLCv2 impl = new DLCv2();
        require(address(impl).code.length > 0, "deployment failed");
        vm.stopBroadcast();
        console2.log("DLCv2 implementation deployed at:", address(impl));
        console2.log("Bytecode size:", address(impl).code.length);
        console2.log("");
        console2.log("Next steps (from canUpgradeAddress):");
        console2.log("  CALLDATA=$(cast calldata 'initializeV2(address)' <ADMIN>)");
        console2.log("  cast send <PROXY> 'upgradeToAndCall(address,bytes)' \\");
        console2.log("    ", address(impl));
        console2.log("    $CALLDATA");
        console2.log("");
        console2.log("initializeV2(address) selector: 0x29b6eca9");
    }
}
