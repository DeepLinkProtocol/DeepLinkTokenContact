// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {DLCv2} from "../src/DLCv2.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IERC20View {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC20Permit {
    function permit(
        address owner, address spender, uint256 value, uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IV1Compat {
    function timeLock() external view returns (address);
    function isLockActive() external view returns (bool);
    function disableUpgrade() external view returns (bool);
    function initSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function calculateLockedAmount(address) external view returns (uint256);
    function getAvailableAmount(address) external view returns (uint256, uint256);
}

/// Forks DBC mainnet, simulates `sudo.setStorage(slot 6 = upgrader)`, then
/// performs v1→v2 UUPS upgrade and asserts:
///   - All ERC20 state preserved (totalSupply / balances / name / symbol / decimals / allowances)
///   - v1 sequential slots 0/1/2/3/4/5/7 unchanged
///   - v1 lock state intact (timeLock / isLockActive / disableUpgrade)
///   - v1 lock view functions still work
///   - permit() still works (EIP712 cache preserved)
///   - v2 features active (admin set, forceTransfer works, canUpgradeAddress cleared by v1)
///
/// Run:
///   forge test --match-contract DLCv2ForkTest \
///       --fork-url https://rpc.dbcwallet.io \
///       -vvv
contract DLCv2ForkTest is Test {
    address constant PROXY = 0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe;
    address constant V1_IMPL = 0xa72e3ebB05131fb6A1DFE6546C0A72c30f424477;
    address constant WHALE = 0xAF49734cF87d36AA4881F5B2f05A65F08063818b;

    bytes32 constant ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant INITIALIZABLE_NS =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ERC20_NS =
        0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
    bytes32 constant DLCV2_NS =
        0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400;

    address internal upgrader = address(0xA11CE);
    address internal initialAdmin = address(0xB0B);

    // Pre-upgrade snapshot
    uint256 internal preTotalSupply;
    uint256 internal preWhaleBalance;
    string  internal preName;
    string  internal preSymbol;
    uint8   internal preDecimals;
    address internal preImplAddress;
    bytes32 internal preSlot0;
    bytes32 internal preSlot1;
    bytes32 internal preSlot2;
    bytes32 internal preSlot3;
    bytes32 internal preSlot4;
    bytes32 internal preSlot5;
    bytes32 internal preSlot7;
    uint64  internal preInitialized;
    address internal preTimeLock;
    bool    internal preIsLockActive;
    bool    internal preDisableUpgrade;
    uint256 internal preInitSupply;
    uint256 internal preMaxSupply;

    modifier onlyMainnetFork() {
        if (block.chainid != 19880818) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 19880818) return;

        preTotalSupply  = IERC20View(PROXY).totalSupply();
        preWhaleBalance = IERC20View(PROXY).balanceOf(WHALE);
        preName         = IERC20View(PROXY).name();
        preSymbol       = IERC20View(PROXY).symbol();
        preDecimals     = IERC20View(PROXY).decimals();
        preImplAddress  = address(uint160(uint256(vm.load(PROXY, ERC1967_IMPL_SLOT))));
        preSlot0        = vm.load(PROXY, bytes32(uint256(0)));
        preSlot1        = vm.load(PROXY, bytes32(uint256(1)));
        preSlot2        = vm.load(PROXY, bytes32(uint256(2)));
        preSlot3        = vm.load(PROXY, bytes32(uint256(3)));
        preSlot4        = vm.load(PROXY, bytes32(uint256(4)));
        preSlot5        = vm.load(PROXY, bytes32(uint256(5)));
        preSlot7        = vm.load(PROXY, bytes32(uint256(7)));
        preInitialized  = uint64(uint256(vm.load(PROXY, INITIALIZABLE_NS)));

        preTimeLock        = IV1Compat(PROXY).timeLock();
        preIsLockActive    = IV1Compat(PROXY).isLockActive();
        preDisableUpgrade  = IV1Compat(PROXY).disableUpgrade();
        preInitSupply      = IV1Compat(PROXY).initSupply();
        preMaxSupply       = IV1Compat(PROXY).maxSupply();

        console2.log("=== Pre-upgrade snapshot ===");
        console2.log("  totalSupply:    ", preTotalSupply);
        console2.log("  whale balance:  ", preWhaleBalance);
        console2.log("  name:           ", preName);
        console2.log("  symbol:         ", preSymbol);
        console2.log("  v1 impl:        ", preImplAddress);
        console2.log("  _initialized:   ", preInitialized);
        console2.log("  timeLock:       ", preTimeLock);
        console2.log("  isLockActive:   ", preIsLockActive);
        console2.log("  disableUpgrade: ", preDisableUpgrade);
        console2.log("  initSupply:     ", preInitSupply);
        console2.log("  maxSupply:      ", preMaxSupply);

        require(preTotalSupply > 0,        "totalSupply must be non-zero pre-upgrade");
        require(preWhaleBalance > 0,       "whale balance must be non-zero pre-upgrade");
        require(preImplAddress == V1_IMPL, "v1 impl mismatch");
        require(preInitialized == 1,       "v1 Initializable should be 1");
        require(!preDisableUpgrade,        "v1 disableUpgrade set - cannot upgrade");
    }

    function _doUpgrade() internal returns (DLCv2 v2impl) {
        vm.store(PROXY, bytes32(uint256(6)), bytes32(uint256(uint160(upgrader))));
        v2impl = new DLCv2();
        vm.prank(upgrader);
        IUUPS(PROXY).upgradeToAndCall(
            address(v2impl),
            abi.encodeWithSelector(DLCv2.initializeV2.selector, initialAdmin)
        );
    }

    // ════════════════ Core: ERC20 state + v1 storage preservation ══════════════

    function test_upgradeFromMainnet_preservesAllState() public onlyMainnetFork {
        assertEq(DLCv2(PROXY).canUpgradeAddress(), address(0), "slot 6 should be 0 pre-sudo");

        DLCv2 v2impl = _doUpgrade();

        // User-visible ERC20 state - unchanged
        assertEq(IERC20View(PROXY).totalSupply(),    preTotalSupply,  "totalSupply changed");
        assertEq(IERC20View(PROXY).balanceOf(WHALE), preWhaleBalance, "whale balance changed");
        assertEq(IERC20View(PROXY).decimals(),       preDecimals,     "decimals changed");
        assertEq(keccak256(bytes(IERC20View(PROXY).name())),   keccak256(bytes(preName)));
        assertEq(keccak256(bytes(IERC20View(PROXY).symbol())), keccak256(bytes(preSymbol)));

        // v1 sequential slots that v2 reads/writes should be IDENTICAL after
        // upgrade EXCEPT slot 6 (canUpgradeAddress) which v1 cleared.
        assertEq(vm.load(PROXY, bytes32(uint256(0))), preSlot0, "slot 0 (timeLock+isLockActive) corrupted");
        assertEq(vm.load(PROXY, bytes32(uint256(1))), preSlot1, "slot 1 (walletLockTimestamp base) corrupted");
        assertEq(vm.load(PROXY, bytes32(uint256(2))), preSlot2, "slot 2 (initSupply) corrupted");
        assertEq(vm.load(PROXY, bytes32(uint256(3))), preSlot3, "slot 3 (maxSupply) corrupted");
        assertEq(vm.load(PROXY, bytes32(uint256(4))), preSlot4, "slot 4 (minter2MintAmount base) corrupted");
        assertEq(vm.load(PROXY, bytes32(uint256(5))), preSlot5, "slot 5 (lockTransferAdmins base) corrupted");
        // slot 6: v1 cleared it during _authorizeUpgrade; we wrote it pre-upgrade
        // via vm.store. Both equal address(0) after upgrade.
        assertEq(vm.load(PROXY, bytes32(uint256(6))), bytes32(0), "slot 6 should be cleared by v1");
        assertEq(vm.load(PROXY, bytes32(uint256(7))), preSlot7, "slot 7 (disableUpgrade) corrupted");

        // v1 view functions still work and return same values
        assertEq(IV1Compat(PROXY).timeLock(),        preTimeLock);
        assertEq(IV1Compat(PROXY).isLockActive(),    preIsLockActive);
        assertEq(IV1Compat(PROXY).disableUpgrade(),  preDisableUpgrade);
        assertEq(IV1Compat(PROXY).initSupply(),      preInitSupply);
        assertEq(IV1Compat(PROXY).maxSupply(),       preMaxSupply);

        // v2 features active
        assertEq(DLCv2(PROXY).admin(),               initialAdmin);
        assertEq(DLCv2(PROXY).canUpgradeAddress(),   address(0), "slot 6 should remain 0");
        assertEq(DLCv2(PROXY).forceTransferCount(),  0);

        // Impl slot points to v2
        address postImpl = address(uint160(uint256(vm.load(PROXY, ERC1967_IMPL_SLOT))));
        assertEq(postImpl, address(v2impl), "ERC1967 impl slot not updated");

        // Initializable 1 → 2
        uint64 postInit = uint64(uint256(vm.load(PROXY, INITIALIZABLE_NS)));
        assertEq(postInit, 2, "Initializable should bump 1->2");
    }

    // ════════════════════════════ Allowance preservation ════════════════════════

    function test_upgrade_preservesAllowance() public onlyMainnetFork {
        address spender = address(0xBEEF);
        uint256 approval = 12345 ether;

        vm.prank(WHALE);
        IERC20View(PROXY).approve(spender, approval);
        assertEq(IERC20View(PROXY).allowance(WHALE, spender), approval);

        _doUpgrade();

        assertEq(
            IERC20View(PROXY).allowance(WHALE, spender),
            approval,
            "allowance lost across upgrade"
        );
    }

    // ════════════════════════════ Initializable replay ══════════════════════════

    function test_upgrade_reinitializerReplayBlocked() public onlyMainnetFork {
        _doUpgrade();

        vm.prank(upgrader);
        vm.expectRevert(); // InvalidInitialization
        DLCv2(PROXY).initializeV2(address(0xDEAD));
    }

    // ════════════════════════════ EIP712 / Permit ═══════════════════════════════

    function test_upgrade_permitWorks() public onlyMainnetFork {
        _doUpgrade();

        uint256 ownerPk = 0xA11CE;
        address ownerAddr = vm.addr(ownerPk);

        bytes32 ownerBalSlot = keccak256(abi.encode(ownerAddr, ERC20_NS));
        vm.store(PROXY, ownerBalSlot, bytes32(uint256(1000 ether)));

        address spender = address(0xBEEF);
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(PROXY).nonces(ownerAddr);

        bytes32 domainSeparator = IERC20Permit(PROXY).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            ownerAddr, spender, value, nonce, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        IERC20Permit(PROXY).permit(ownerAddr, spender, value, deadline, v, r, s);
        assertEq(IERC20View(PROXY).allowance(ownerAddr, spender), value);
    }

    // ════════════════════════════ ForceTransfer on whale ═══════════════════════

    function test_forceTransfer_worksOnRealWhale() public onlyMainnetFork {
        _doUpgrade();

        address recovery = address(0xBEEF);
        uint256 amount   = 1 ether;

        uint256 whaleBefore    = IERC20View(PROXY).balanceOf(WHALE);
        uint256 recoveryBefore = IERC20View(PROXY).balanceOf(recovery);

        vm.prank(initialAdmin);
        DLCv2(PROXY).forceTransfer(WHALE, recovery, amount);

        assertEq(IERC20View(PROXY).balanceOf(WHALE),    whaleBefore - amount);
        assertEq(IERC20View(PROXY).balanceOf(recovery), recoveryBefore + amount);
        assertEq(DLCv2(PROXY).forceTransferCount(), 1);
    }

    // ════════════════════════════ setAdmin (Option A) ══════════════════════════
    //
    // Option A: admin can self-rotate INSTANTLY; timeLock retains 24h rescue.
    // Negative case uses a random caller, NOT initialAdmin (which CAN rotate).

    function test_setAdmin_optionA_viaForkMainnet() public onlyMainnetFork {
        _doUpgrade();
        assertEq(DLCv2(PROXY).admin(), initialAdmin);

        // (1) Random caller (neither admin nor timeLock) is rejected with the
        //     NotAdminOrTimeLock custom error.
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdminOrTimeLock.selector, attacker));
        DLCv2(PROXY).setAdmin(address(0xCAFE));

        // (2) Current admin self-rotates instantly (Option A primary path).
        vm.prank(initialAdmin);
        DLCv2(PROXY).setAdmin(address(0xCAFE));
        assertEq(DLCv2(PROXY).admin(), address(0xCAFE), "admin self-rotate failed");

        // (3) Real timeLock (slot 0 v1 field) can override the stuck admin
        //     to a new safe address. This is the 24h emergency rescue path.
        address realTimeLock = IV1Compat(PROXY).timeLock();
        vm.prank(realTimeLock);
        DLCv2(PROXY).setAdmin(address(0xBEEF));
        assertEq(DLCv2(PROXY).admin(), address(0xBEEF), "timeLock rescue failed");

        // (4) The previously rotated-out admin loses rotation capability.
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdminOrTimeLock.selector, address(0xCAFE)));
        DLCv2(PROXY).setAdmin(address(0xCAFE));
    }

    // ════════════════════════════ Rollback ══════════════════════════════════════

    function test_rollback_v2BackToV1_preservesState() public onlyMainnetFork {
        _doUpgrade();

        // Need fresh slot-6 grant from timeLock to re-upgrade
        address realTimeLock = IV1Compat(PROXY).timeLock();
        vm.prank(realTimeLock);
        DLCv2(PROXY).setUpgradePermission(upgrader);

        vm.prank(upgrader);
        IUUPS(PROXY).upgradeToAndCall(V1_IMPL, "");

        assertEq(IERC20View(PROXY).totalSupply(),    preTotalSupply);
        assertEq(IERC20View(PROXY).balanceOf(WHALE), preWhaleBalance);

        address postImpl = address(uint160(uint256(vm.load(PROXY, ERC1967_IMPL_SLOT))));
        assertEq(postImpl, V1_IMPL, "rollback failed");

        // v2 namespace residue: admin/forceTransferCount still there
        bytes32 adminSlot = vm.load(PROXY, DLCV2_NS);
        assertEq(
            address(uint160(uint256(adminSlot))),
            initialAdmin,
            "v2 admin slot survives rollback - future v3 must zero this"
        );
    }
}
