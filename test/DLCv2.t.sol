// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {DLCv2} from "../src/DLCv2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// Minimal v1 stub mirroring `docs/v1-source/DLC.sol` storage layout AND
/// `_authorizeUpgrade` behaviour (including the canUpgradeAddress=0 clear).
/// Inherits UUPSUpgradeable so the proxy can delegate `upgradeToAndCall` here.
contract DLCv1Stub is Initializable, UUPSUpgradeable {
    // slot 0: timeLock + isLockActive (packed)
    address public timeLock;
    bool public isLockActive;

    struct LockInfo {
        uint256 lockedAt;
        uint256 lockedAmount;
        uint256 unlockAt;
    }

    mapping(address => LockInfo[]) private walletLockTimestamp;  // slot 1
    uint256 public initSupply;                                    // slot 2
    uint256 public maxSupply;                                     // slot 3
    mapping(address => uint256) public minter2MintAmount;         // slot 4
    mapping(address => bool) public lockTransferAdmins;           // slot 5
    address public canUpgradeAddress;                             // slot 6
    bool public disableUpgrade;                                   // slot 7

    function setCanUpgradeAddress(address a) external {
        canUpgradeAddress = a;
    }
    function setTimeLock(address t) external {
        timeLock = t;
    }
    function setIsLockActive(bool v) external {
        isLockActive = v;
    }

    /// MIRRORS REAL v1: clears slot 6 to address(0) at the end. This is the
    /// reason v2's initializeV2 cannot have onlyCanUpgradeAddress.
    function _authorizeUpgrade(address newImplementation) internal override {
        require(disableUpgrade == false, "Has disabled upgrade");
        require(msg.sender == canUpgradeAddress, "Only canUpgradeAddress can upgrade");
        require(newImplementation != address(0), "Invalid implementation address");
        canUpgradeAddress = address(0);
    }
}

/// Minimal ERC20 for rescueOtherTokens tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract DLCv2Test is Test {
    DLCv2 internal v2impl;
    address internal proxyAddr;
    DLCv2 internal proxy;

    address internal upgrader = address(0xA11CE);     // sudo.setStorage-granted slot 6 value
    address internal newAdmin = address(0xB0B);       // v2 admin
    address internal timeLock = address(0x71E1066);   // simulates MultiSigTimeLock
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal carol = address(0xC);

    // Event signatures for vm.expectEmit. Names MUST match OZ to produce same topic0.
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // 1. Deploy v1 stub + proxy
        DLCv1Stub v1impl = new DLCv1Stub();
        ERC1967Proxy p = new ERC1967Proxy(address(v1impl), "");
        proxyAddr = address(p);

        // 2. Set v1 state via the proxy: timeLock, isLockActive, canUpgradeAddress
        DLCv1Stub(proxyAddr).setTimeLock(timeLock);
        DLCv1Stub(proxyAddr).setIsLockActive(true);
        DLCv1Stub(proxyAddr).setCanUpgradeAddress(upgrader);

        // 3. Deploy v2 impl
        v2impl = new DLCv2();

        // 4. Upgrade with atomic initializeV2(admin). This will:
        //    - run v1's _authorizeUpgrade (clears slot 6 = 0)
        //    - delegatecall v2.initializeV2(admin) which sets admin
        vm.prank(upgrader);
        DLCv2(proxyAddr).upgradeToAndCall(
            address(v2impl),
            abi.encodeWithSelector(DLCv2.initializeV2.selector, newAdmin)
        );
        proxy = DLCv2(proxyAddr);

        // 5. Verify v1 cleared slot 6
        assertEq(proxy.canUpgradeAddress(), address(0), "v1 should have cleared slot 6");

        // 6. Mint test balances directly into v5 ERC20 namespace
        _mintViaStorage(alice, 1000 ether);
        _mintViaStorage(bob, 500 ether);
    }

    // ═══════════════════════════ forceTransfer tests ═══════════════════════════

    function test_forceTransfer_movesBalanceBypassingAllowance() public {
        uint256 beforeA = proxy.balanceOf(alice);
        uint256 beforeC = proxy.balanceOf(carol);
        assertEq(proxy.allowance(alice, newAdmin), 0);

        vm.prank(newAdmin);
        proxy.forceTransfer(alice, carol, 300 ether);

        assertEq(proxy.balanceOf(alice), beforeA - 300 ether);
        assertEq(proxy.balanceOf(carol), beforeC + 300 ether);
        assertEq(proxy.forceTransferCount(), 1);
    }

    function test_forceTransfer_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdmin.selector, alice));
        proxy.forceTransfer(alice, carol, 100 ether);
    }

    function test_forceTransfer_revertsZeroAddress() public {
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.ZeroAddress.selector);
        proxy.forceTransfer(address(0), carol, 1 ether);

        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.ZeroAddress.selector);
        proxy.forceTransfer(alice, address(0), 1 ether);
    }

    function test_forceTransfer_revertsZeroAmount() public {
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.InvalidAmount.selector);
        proxy.forceTransfer(alice, carol, 0);
    }

    function test_forceTransfer_revertsSelfTransfer() public {
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.TransferToSelf.selector);
        proxy.forceTransfer(alice, alice, 1 ether);
    }

    function test_forceTransfer_revertsWhenToIsProxy() public {
        // Red-team R-1: forceTransfer must NOT accept the proxy itself as
        // recipient (would create an audit-obfuscation channel via
        // ForceTransfer→WithdrawDLC chain).
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.CannotTouchProxy.selector);
        proxy.forceTransfer(alice, proxyAddr, 1 ether);
    }

    function test_forceTransfer_revertsWhenFromIsProxy() public {
        // Red-team R-1: forceTransfer must NOT drain the proxy's own balance;
        // that's withdrawDLCTo's job (different event signature, different
        // permission model).
        _mintViaStorage(proxyAddr, 100 ether);
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.CannotTouchProxy.selector);
        proxy.forceTransfer(proxyAddr, alice, 1 ether);
    }

    function test_forceTransfer_revertsInsufficientBalance() public {
        uint256 tooMuch = proxy.balanceOf(alice) + 1;
        vm.prank(newAdmin);
        vm.expectRevert(); // ERC20InsufficientBalance
        proxy.forceTransfer(alice, carol, tooMuch);
    }

    function test_forceTransfer_emitsTransferAndForceTransferEvents() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit DLCv2.ForceTransfer(newAdmin, alice, carol, 100 ether, 1);

        vm.prank(newAdmin);
        proxy.forceTransfer(alice, carol, 100 ether);
    }

    function test_forceTransfer_bypassesLockCheck() public {
        // Simulate alice having a lock: write to walletLockTimestamp[alice] via
        // a stub re-write — easier: use timeLock to add lockTransferAdmin + lock
        // alice. But that requires re-entering, so we directly use raw storage.
        // Skipping: just verify forceTransfer works even when isLockActive.
        // (Detailed lock-bypass test below in lock section.)
        assertTrue(proxy.isLockActive(), "lock should be active for this test");

        vm.prank(newAdmin);
        proxy.forceTransfer(alice, carol, 100 ether);
        assertEq(proxy.balanceOf(carol), 100 ether);
    }

    function testFuzz_forceTransfer(address from, address to, uint96 amount) public {
        vm.assume(from != address(0) && to != address(0) && from != to);
        vm.assume(amount > 0 && amount < 1e30);
        vm.assume(from != proxyAddr && to != proxyAddr);

        _mintViaStorage(from, amount);
        uint256 toBefore = proxy.balanceOf(to);

        vm.prank(newAdmin);
        proxy.forceTransfer(from, to, amount);

        assertEq(proxy.balanceOf(from), 0);
        assertEq(proxy.balanceOf(to), toBefore + amount);
    }

    // ═══════════════════════════ setAdmin tests ════════════════════════════════

    function test_setAdmin_rejectsRandom() public {
        // Random callers (not admin, not timeLock) cannot rotate.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdminOrTimeLock.selector, alice));
        proxy.setAdmin(alice);

        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdminOrTimeLock.selector, upgrader));
        proxy.setAdmin(upgrader);
    }

    function test_setAdmin_adminSelfRotates_instant() public {
        // Option A: current admin can rotate themselves WITHOUT timeLock delay.
        address fresh = address(0xCAFE);
        address next  = address(0xBEEF);
        vm.expectEmit(true, true, false, false);
        emit DLCv2.AdminChanged(newAdmin, fresh);

        vm.prank(newAdmin); // current admin
        proxy.setAdmin(fresh);
        assertEq(proxy.admin(), fresh);

        // Old admin can no longer setAdmin (alice fixture address 0xA is in
        // the precompile range, so use a real >0xff address for the negative).
        address otherTarget = address(0xABCD);
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdminOrTimeLock.selector, newAdmin));
        proxy.setAdmin(otherTarget);

        // Fresh admin can rotate further
        vm.prank(fresh);
        proxy.setAdmin(next);
        assertEq(proxy.admin(), next);
    }

    function test_setAdmin_timeLockRotates() public {
        address newOne = address(0xDEAD);
        vm.expectEmit(true, true, false, false);
        emit DLCv2.AdminChanged(newAdmin, newOne);

        vm.prank(timeLock);
        proxy.setAdmin(newOne);
        assertEq(proxy.admin(), newOne);
    }

    function test_setAdmin_timeLockCanOverrideStuckAdmin() public {
        // Simulates: admin keys lost/stuck. MultiSigTimeLock recovers by
        // setting a fresh admin even when current admin can no longer sign.
        address recovered = address(0xFEED);
        vm.prank(timeLock);
        proxy.setAdmin(recovered);
        assertEq(proxy.admin(), recovered);

        // Verify old admin (stuck) can no longer act
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdmin.selector, newAdmin));
        proxy.forceTransfer(alice, carol, 1 ether);

        // Recovered admin can act
        vm.prank(recovered);
        proxy.forceTransfer(alice, carol, 1 ether);
        assertEq(proxy.balanceOf(carol), 1 ether);
    }

    function test_setAdmin_revertsZeroAddress() public {
        vm.prank(timeLock);
        vm.expectRevert(DLCv2.ZeroAddress.selector);
        proxy.setAdmin(address(0));

        vm.prank(newAdmin); // also from admin self-rotate path
        vm.expectRevert(DLCv2.ZeroAddress.selector);
        proxy.setAdmin(address(0));
    }

    function test_setAdmin_revertsProxySelf() public {
        // setAdmin(address(proxy)) would brick admin rotation (proxy can't tx).
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.InvalidAdmin.selector, proxyAddr));
        proxy.setAdmin(proxyAddr);

        vm.prank(timeLock);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.InvalidAdmin.selector, proxyAddr));
        proxy.setAdmin(proxyAddr);
    }

    function test_setAdmin_revertsPrecompileRange() public {
        // 0x1 (ecrecover), 0x4 (identity), 0xff (boundary inclusive) — all bricked admins.
        address[3] memory precompiles = [
            address(uint160(0x1)),
            address(uint160(0x4)),
            address(uint160(0xff))
        ];
        for (uint256 i = 0; i < precompiles.length; i++) {
            vm.prank(newAdmin);
            vm.expectRevert(abi.encodeWithSelector(DLCv2.InvalidAdmin.selector, precompiles[i]));
            proxy.setAdmin(precompiles[i]);
        }

        // 0x100 is just above the precompile range and MUST be allowed.
        vm.prank(newAdmin);
        proxy.setAdmin(address(uint160(0x100)));
        assertEq(proxy.admin(), address(uint160(0x100)), "boundary above precompiles should pass");
    }

    function test_setAdmin_adminEqualTimeLock_bothPredicatesWork() public {
        // Operational footgun: setAdmin(timeLock). After this, msg.sender ==
        // admin AND msg.sender == timeLock collapse to the same address; the
        // modifier still works via OR semantics.
        vm.prank(newAdmin);
        proxy.setAdmin(timeLock);
        assertEq(proxy.admin(), timeLock);

        // timeLock (now both admin AND timeLock) can still rotate to a
        // non-precompile address.
        address restored = address(0xCAFE);
        vm.prank(timeLock);
        proxy.setAdmin(restored);
        assertEq(proxy.admin(), restored);
    }

    function test_requestSetAdmin_returnsCalldata() public view {
        bytes memory data = proxy.requestSetAdmin(address(0xCAFE));
        bytes memory expected = abi.encodeWithSignature("setAdmin(address)", address(0xCAFE));
        assertEq(keccak256(data), keccak256(expected));
    }

    // ═══════════════════════════ Initializer tests ═════════════════════════════

    function test_initializeV2_cannotBeCalledTwice() public {
        // setUp already invoked it; second call must revert via reinitializer.
        vm.prank(upgrader);
        vm.expectRevert(); // InvalidInitialization
        proxy.initializeV2(address(0xCAFE));
    }

    function test_initializeV2_revertsZeroAdmin() public {
        // Fresh proxy: reinitializer hasn't been consumed yet.
        DLCv1Stub v1impl = new DLCv1Stub();
        ERC1967Proxy p = new ERC1967Proxy(address(v1impl), "");
        DLCv1Stub(address(p)).setCanUpgradeAddress(upgrader);

        DLCv2 freshImpl = new DLCv2();
        vm.prank(upgrader);
        vm.expectRevert(DLCv2.ZeroAddress.selector);
        DLCv2(address(p)).upgradeToAndCall(
            address(freshImpl),
            abi.encodeWithSelector(DLCv2.initializeV2.selector, address(0))
        );
    }

    // ═══════════════════════════ Upgrade-gate tests ════════════════════════════

    function test_upgrade_revertsForNonCanUpgrade() public {
        // After setUp, slot 6 was cleared. So nobody can upgrade until
        // timeLock calls setUpgradePermission again.
        DLCv2 newImpl = new DLCv2();
        vm.prank(alice);
        vm.expectRevert("Only canUpgradeAddress can upgrade");
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_v2ToV2_requiresSetUpgradePermission() public {
        DLCv2 newImpl = new DLCv2();

        // Direct upgrade fails (slot 6 = 0 from prior upgrade)
        vm.prank(upgrader);
        vm.expectRevert("Only canUpgradeAddress can upgrade");
        proxy.upgradeToAndCall(address(newImpl), "");

        // Increment forceTransferCount BEFORE upgrade so we can verify the
        // namespace's second field is preserved (not just the first).
        vm.prank(newAdmin);
        proxy.forceTransfer(alice, carol, 1 ether);
        assertEq(proxy.forceTransferCount(), 1, "pre-upgrade counter setup failed");

        // timeLock authorises upgrader via setUpgradePermission
        vm.prank(timeLock);
        proxy.setUpgradePermission(upgrader);
        assertEq(proxy.canUpgradeAddress(), upgrader);

        // Now upgrade works, and slot 6 is cleared again
        vm.prank(upgrader);
        proxy.upgradeToAndCall(address(newImpl), "");
        assertEq(proxy.canUpgradeAddress(), address(0), "v2 should clear slot 6 like v1");

        // v2 state preserved across the v2→v2 upgrade
        assertEq(proxy.admin(), newAdmin);
        assertEq(proxy.balanceOf(alice), 1000 ether - 1 ether);
        assertEq(proxy.forceTransferCount(), 1, "namespace field 2 must survive v2->v2 upgrade");

        // Direct-slot assertions: verify the ERC-7201 namespace is intact
        bytes32 ns = 0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400;
        assertEq(
            address(uint160(uint256(vm.load(proxyAddr, ns)))),
            newAdmin,
            "namespace field 1 (admin) must equal pre-upgrade value"
        );
        assertEq(
            uint256(vm.load(proxyAddr, bytes32(uint256(ns) + 1))),
            1,
            "namespace field 2 (forceTransferCount) slot read must equal 1"
        );
    }

    function test_disableUpgrade_blocksUpgrade() public {
        vm.prank(timeLock);
        proxy.disableContractUpgrade();
        assertTrue(proxy.disableUpgrade());

        // Even with valid canUpgradeAddress, disableUpgrade blocks
        vm.prank(timeLock);
        vm.expectRevert("Contract upgrade is disabled");
        proxy.setUpgradePermission(upgrader);
    }

    // ═══════════════════════════ Storage-layout sanity ═════════════════════════

    function test_namespace_slot_matches_formula() public pure {
        bytes32 expected = keccak256(
            abi.encode(uint256(keccak256("deeplink.dlc.v2")) - 1)
        ) & ~bytes32(uint256(0xff));
        bytes32 hardcoded = 0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400;
        assertEq(expected, hardcoded);
    }

    function test_namespace_does_not_collide() public pure {
        bytes32 dlcNs       = 0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400;
        bytes32 erc20Ns     = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
        bytes32 initNs      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        bytes32 erc1967Impl = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 eip712Ns = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 noncesNs = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Nonces")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 reentNs  = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff));

        assertTrue(dlcNs != erc20Ns);
        assertTrue(dlcNs != initNs);
        assertTrue(dlcNs != eip712Ns);
        assertTrue(dlcNs != noncesNs);
        assertTrue(dlcNs != reentNs);
        assertTrue(dlcNs != erc1967Impl);
        // dlcNs+0 and dlcNs+1 must not equal any v1 sequential slot (0..7).
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(uint256(dlcNs)   != i);
            assertTrue(uint256(dlcNs)+1 != i);
        }
    }

    // ═══════════════════════════ Standard ERC20 still works ════════════════════

    function test_transfer_normalFlowStillWorks() public {
        uint256 beforeA = proxy.balanceOf(alice);
        uint256 beforeB = proxy.balanceOf(bob);
        vm.prank(alice);
        proxy.transfer(bob, 100 ether);
        assertEq(proxy.balanceOf(alice), beforeA - 100 ether);
        assertEq(proxy.balanceOf(bob), beforeB + 100 ether);
    }

    function test_approve_and_transferFrom_works() public {
        vm.prank(alice);
        proxy.approve(bob, 50 ether);
        vm.prank(bob);
        proxy.transferFrom(alice, carol, 50 ether);
        assertEq(proxy.balanceOf(carol), 50 ether);
        assertEq(proxy.allowance(alice, bob), 0);
    }

    // ═══════════════════════════ v1 lock system preserved ══════════════════════

    function test_lockSystem_transferAndLock_locksRecipient() public {
        // timeLock adds carol as a lockTransferAdmin
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        assertTrue(proxy.lockTransferAdmins(carol));

        // Carol needs balance to transfer-and-lock to bob
        _mintViaStorage(carol, 200 ether);

        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        // Bob now has +100 ether but they're locked
        (uint256 total, uint256 available) = proxy.getAvailableAmount(bob);
        assertEq(total, 600 ether);   // 500 from setUp + 100 newly received
        assertEq(available, 500 ether, "newly received 100 should be locked");

        // Bob cannot transfer the locked 100
        vm.prank(bob);
        vm.expectRevert("Insufficient unlocked balance");
        proxy.transfer(alice, 501 ether);

        // Bob CAN transfer 500 (the unlocked portion)
        vm.prank(bob);
        proxy.transfer(alice, 500 ether);
    }

    function test_lockSystem_unlocksAfterTime() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);

        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        // Skip 31 days
        vm.warp(block.timestamp + 31 days);

        // Lock expired, bob can transfer all 600
        vm.prank(bob);
        proxy.transfer(alice, 600 ether);
        assertEq(proxy.balanceOf(bob), 0);
    }

    function test_lockSystem_disabledAllowsTransfer() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);
        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        // Now disable lock globally
        vm.prank(timeLock);
        proxy.disableLockPermanently();
        assertFalse(proxy.isLockActive());

        // Bob can transfer everything despite the lock entry existing
        vm.prank(bob);
        proxy.transfer(alice, 600 ether);
    }

    function test_lockSystem_forceTransferBypassesLock() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);
        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        // Confirm bob is locked
        (, uint256 availableBob) = proxy.getAvailableAmount(bob);
        assertEq(availableBob, 500 ether);

        // Admin forceTransfer can move the LOCKED tokens
        vm.prank(newAdmin);
        proxy.forceTransfer(bob, alice, 600 ether);
        assertEq(proxy.balanceOf(bob), 0);
        assertEq(proxy.balanceOf(alice), 1000 ether + 600 ether);
    }

    function test_lockSystem_addRemoveLockAdmin_onlyTimeLock() public {
        vm.prank(alice);
        vm.expectRevert("Not multi sig time lock contract");
        proxy.addLockTransferAdmin(carol);

        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        assertTrue(proxy.lockTransferAdmins(carol));

        vm.prank(timeLock);
        proxy.removeLockTransferAdmin(carol);
        assertFalse(proxy.lockTransferAdmins(carol));
    }

    function test_lockSystem_updateLockDuration_extendsLock() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);

        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 10 days);

        // timeLock extends to 60 days
        vm.prank(timeLock);
        proxy.updateLockDuration(bob, 60 days);

        // After 30 days, still locked (was 10d, now 60d)
        vm.warp(block.timestamp + 30 days);
        (, uint256 available) = proxy.getAvailableAmount(bob);
        assertEq(available, 500 ether, "still locked after extension");
    }

    function test_lockSystem_transferAndLock_revertsZeroDuration() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 10 ether);

        vm.prank(carol);
        vm.expectRevert("Invalid lock duration");
        proxy.transferAndLock(bob, 1 ether, 0);
    }

    function test_lockSystem_transferAndLock_revertsAt100Entries() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 1000 ether);

        // Push 99 entries (the 100th would be the boundary; the check is
        // `length < 100` so length=99 still passes, length=100 fails).
        for (uint256 i = 0; i < 99; i++) {
            vm.prank(carol);
            proxy.transferAndLock(bob, 1 ether, 1 days);
        }

        // 100th entry succeeds (length now == 99 → still < 100)
        vm.prank(carol);
        proxy.transferAndLock(bob, 1 ether, 1 days);

        // 101st entry must revert
        vm.prank(carol);
        vm.expectRevert("Too many lock entries");
        proxy.transferAndLock(bob, 1 ether, 1 days);
    }

    function test_lockSystem_getLockAmountAndUnlockAt_revertsOutOfRange() public {
        // bob has no locks → any index reverts
        vm.expectRevert("Index out of range");
        proxy.getLockAmountAndUnlockAt(bob, 0);

        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 10 ether);
        vm.prank(carol);
        proxy.transferAndLock(bob, 1 ether, 1 days);

        // index 0 now valid, index 1 still out of range
        (uint256 amt, uint256 unlockAt) = proxy.getLockAmountAndUnlockAt(bob, 0);
        assertEq(amt, 1 ether);
        assertEq(unlockAt, block.timestamp + 1 days);

        vm.expectRevert("Index out of range");
        proxy.getLockAmountAndUnlockAt(bob, 1);
    }

    function test_lockSystem_transferFrom_revertsWhenLocked() public {
        // Setup: carol minted 200, sends 100 locked to bob (now bob = 500+100,
        // carol = 100). Lock = 100 ether for 30 days on bob.
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);
        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        // bob approves alice to spend 600 ether
        vm.prank(bob);
        proxy.approve(alice, 600 ether);

        // alice transferFrom 501 ether — fails (only 500 unlocked of bob's 600)
        vm.prank(alice);
        vm.expectRevert("Insufficient unlocked balance");
        proxy.transferFrom(bob, carol, 501 ether);

        // alice CAN transferFrom 500 ether (the unlocked portion)
        // Final carol balance = 100 (post-transferAndLock) + 500 (received) = 600 ether
        vm.prank(alice);
        proxy.transferFrom(bob, carol, 500 ether);
        assertEq(proxy.balanceOf(carol), 600 ether);
    }

    function test_lockSystem_disableEnableRoundTrip() public {
        assertTrue(proxy.isLockActive(), "setUp set true");

        vm.prank(timeLock);
        proxy.disableLockPermanently();
        assertFalse(proxy.isLockActive(), "function name misleading - disable is reversible");

        vm.prank(timeLock);
        proxy.enableLockPermanently();
        assertTrue(proxy.isLockActive(), "re-enabled by enableLockPermanently");
    }

    function test_burn_respectsLock() public {
        vm.prank(timeLock);
        proxy.addLockTransferAdmin(carol);
        _mintViaStorage(carol, 200 ether);
        vm.prank(carol);
        proxy.transferAndLock(bob, 100 ether, 30 days);

        vm.prank(bob);
        vm.expectRevert("Insufficient unlocked balance");
        proxy.burn(501 ether);

        vm.prank(bob);
        proxy.burn(500 ether); // unlocked portion
    }

    // ═══════════════════════════ withdrawDLCTo preserved ═══════════════════════

    function test_withdrawDLCTo_onlyHardcodedAddress() public {
        // Mint some DLC to the proxy itself
        _mintViaStorage(proxyAddr, 100 ether);

        // Non-permitted caller fails
        vm.prank(alice);
        vm.expectRevert("has no permission");
        proxy.withdrawDLCTo(alice, 10 ether);

        // The hardcoded address succeeds
        address hardcoded = 0x36Ede4Fe3CD9F270747f07c15D8098F10dF6D8e8;
        vm.prank(hardcoded);
        proxy.withdrawDLCTo(carol, 10 ether);
        assertEq(proxy.balanceOf(carol), 10 ether);
    }

    // ═══════════════════════════ rescueOtherTokens tests ═══════════════════════

    function test_rescueOtherTokens_nonAdminReverts() public {
        MockERC20 m = new MockERC20();
        m.mint(proxyAddr, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DLCv2.NotAdmin.selector, alice));
        proxy.rescueOtherTokens(address(m), carol, 100 ether);
    }

    function test_rescueOtherTokens_cannotRescueSelf() public {
        vm.prank(newAdmin);
        vm.expectRevert(DLCv2.CannotRescueDLC.selector);
        proxy.rescueOtherTokens(proxyAddr, carol, 1 ether);
    }

    function test_rescueOtherTokens_happyPath() public {
        MockERC20 m = new MockERC20();
        m.mint(proxyAddr, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit DLCv2.Rescued(address(m), carol, 100 ether);

        vm.prank(newAdmin);
        proxy.rescueOtherTokens(address(m), carol, 100 ether);
        assertEq(m.balanceOf(carol), 100 ether);
    }

    // ═══════════════════════════ Helpers ═══════════════════════════════════════

    bytes32 private constant ERC20_NAMESPACE =
        0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    function _mintViaStorage(address who, uint256 amount) internal {
        bytes32 balanceSlot = keccak256(abi.encode(who, ERC20_NAMESPACE));
        bytes32 oldBal = vm.load(proxyAddr, balanceSlot);
        vm.store(proxyAddr, balanceSlot, bytes32(uint256(oldBal) + amount));
        bytes32 supplySlot = bytes32(uint256(ERC20_NAMESPACE) + 2);
        uint256 oldSupply = uint256(vm.load(proxyAddr, supplySlot));
        vm.store(proxyAddr, supplySlot, bytes32(oldSupply + amount));
    }
}
