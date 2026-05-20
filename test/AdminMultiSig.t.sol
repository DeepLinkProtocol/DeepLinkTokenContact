// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {AdminMultiSig} from "../src/AdminMultiSig.sol";

/// Minimal target for end-to-end test: stores last (caller, value, arg).
contract MockTarget {
    address public lastCaller;
    uint256 public lastValue;
    uint256 public lastArg;
    bool    public shouldRevert;

    function setRevert(bool v) external { shouldRevert = v; }

    function ping(uint256 arg) external payable {
        if (shouldRevert) revert("mock target revert");
        lastCaller = msg.sender;
        lastValue  = msg.value;
        lastArg    = arg;
    }
}

/// Re-entrant target that tries to re-execute the same proposal in flight.
contract ReentrantTarget {
    AdminMultiSig public ms;
    uint256 public lastReentrantId;
    bool    public lastReentrantSucceeded;

    constructor(AdminMultiSig m) { ms = m; }

    function attack(uint256 id) external payable {
        // Attempt to re-execute the same proposal while it's executing.
        try ms.execute(id) {
            lastReentrantId        = id;
            lastReentrantSucceeded = true;
        } catch {
            lastReentrantId        = id;
            lastReentrantSucceeded = false;
        }
    }
}

contract AdminMultiSigTest is Test {
    AdminMultiSig internal ms;
    address internal s1 = address(0x1111);
    address internal s2 = address(0x2222);
    address internal s3 = address(0x3333);
    address internal outsider = address(0xBADBAD);

    MockTarget internal mock;

    event ProposalCreated(uint256 indexed id, address indexed proposer, address indexed target, uint256 value, bytes data);
    event ProposalConfirmed(uint256 indexed id, address indexed signer, uint8 confirmCount);
    event ProposalRevoked(uint256 indexed id, address indexed signer, uint8 confirmCount);
    event ProposalCancelled(uint256 indexed id, address indexed canceller);
    event ProposalExecuted(uint256 indexed id, address indexed executor, bytes returnData);

    function setUp() public {
        ms = new AdminMultiSig(s1, s2, s3);
        mock = new MockTarget();
    }

    function _submitAndFullyConfirm(address target, uint256 value, bytes memory data)
        internal returns (uint256 id)
    {
        vm.prank(s1);
        id = ms.submit(target, value, data);
        vm.prank(s2);
        ms.confirm(id);
        vm.prank(s3);
        ms.confirm(id);
    }

    // ════════════════════════════ Constructor ══════════════════════════════════

    function test_ctor_rejectsZeroSigner() public {
        vm.expectRevert(AdminMultiSig.ZeroSigner.selector);
        new AdminMultiSig(address(0), s2, s3);
        vm.expectRevert(AdminMultiSig.ZeroSigner.selector);
        new AdminMultiSig(s1, address(0), s3);
        vm.expectRevert(AdminMultiSig.ZeroSigner.selector);
        new AdminMultiSig(s1, s2, address(0));
    }

    function test_ctor_rejectsDuplicateSigner() public {
        vm.expectRevert(AdminMultiSig.DuplicateSigner.selector);
        new AdminMultiSig(s1, s1, s2);
        vm.expectRevert(AdminMultiSig.DuplicateSigner.selector);
        new AdminMultiSig(s1, s2, s1);
        vm.expectRevert(AdminMultiSig.DuplicateSigner.selector);
        new AdminMultiSig(s1, s2, s2);
    }

    function test_ctor_setsImmutables() public view {
        (address a, address b, address c) = ms.signers();
        assertEq(a, s1);
        assertEq(b, s2);
        assertEq(c, s3);
        assertEq(ms.THRESHOLD(), 3);
        assertTrue(ms.isSigner(s1));
        assertTrue(ms.isSigner(s2));
        assertTrue(ms.isSigner(s3));
        assertFalse(ms.isSigner(outsider));
    }

    // ════════════════════════════ Threshold strictness ═════════════════════════

    function test_execute_revertsBelowThreshold() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, abi.encodeCall(MockTarget.ping, (42)));
        // Only 1 confirm so far (the implicit submitter)
        vm.prank(outsider); // anyone can attempt execute (Q1=B design)
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.InsufficientConfirmations.selector, id, 1, 3));
        ms.execute(id);

        vm.prank(s2);
        ms.confirm(id);
        // Now 2 confirms — still short
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.InsufficientConfirmations.selector, id, 2, 3));
        ms.execute(id);

        vm.prank(s3);
        ms.confirm(id);
        // 3 confirms — should execute
        vm.prank(outsider);
        ms.execute(id);
        assertEq(mock.lastArg(), 42);
    }

    function test_execute_permissionless_anyoneCanRelay() public {
        uint256 id = _submitAndFullyConfirm(
            address(mock), 0, abi.encodeCall(MockTarget.ping, (7))
        );
        // Non-signer can execute (Q1=B design choice)
        vm.prank(outsider);
        ms.execute(id);
        assertEq(mock.lastArg(), 7);
        assertEq(mock.lastCaller(), address(ms));
    }

    // ════════════════════════════ Replay / re-entrancy ═════════════════════════

    function test_execute_revertsOnReplay() public {
        uint256 id = _submitAndFullyConfirm(
            address(mock), 0, abi.encodeCall(MockTarget.ping, (1))
        );
        ms.execute(id);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyExecuted.selector, id));
        ms.execute(id);
    }

    function test_execute_reentrancyBlocked() public {
        ReentrantTarget r = new ReentrantTarget(ms);
        uint256 id = _submitAndFullyConfirm(
            address(r), 0, abi.encodeCall(ReentrantTarget.attack, (1)) // attack(id=1) will be set below
        );
        // Re-fetch id since auto-counter started; recompute exact id for the attack
        // arg should equal `id` (the executing proposal id)
        // Simpler approach: submit a fresh proposal with hardcoded id arg matching real id
        // Since first id=1 already used, redo:
        ReentrantTarget r2 = new ReentrantTarget(ms);
        vm.prank(s1);
        uint256 id2 = ms.submit(address(r2), 0, abi.encodeCall(ReentrantTarget.attack, (id + 1)));
        vm.prank(s2); ms.confirm(id2);
        vm.prank(s3); ms.confirm(id2);
        // id2 should equal id+1
        assertEq(id2, id + 1, "expected next id sequence");
        ms.execute(id2);
        // The reentrant attack should have FAILED (caught) because executed=true
        assertFalse(r2.lastReentrantSucceeded(), "reentrant execute must be blocked");
    }

    // ════════════════════════════ Revoke state machine ═════════════════════════

    function test_revoke_cyclesProperly() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, "");
        // Count = 1
        (, , , , uint8 c0, , ) = ms.getProposal(id);
        assertEq(c0, 1);

        vm.prank(s2); ms.confirm(id);       // 2
        vm.prank(s2); ms.revoke(id);        // 1
        vm.prank(s2); ms.confirm(id);       // 2
        vm.prank(s2); ms.revoke(id);        // 1
        vm.prank(s2); ms.confirm(id);       // 2
        (, , , , uint8 c1, , ) = ms.getProposal(id);
        assertEq(c1, 2);

        // Cannot execute with 2 confirms
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.InsufficientConfirmations.selector, id, 2, 3));
        ms.execute(id);
    }

    function test_revoke_revertsIfNotConfirmed() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, "");
        // s2 never confirmed
        vm.prank(s2);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.NotConfirmed.selector, id, s2));
        ms.revoke(id);
    }

    // ════════════════════════════ Non-signer access ════════════════════════════

    function test_submit_rejectsNonSigner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.NotSigner.selector, outsider));
        ms.submit(address(mock), 0, "");
    }

    function test_confirm_rejectsNonSigner() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, "");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.NotSigner.selector, outsider));
        ms.confirm(id);
    }

    function test_revoke_rejectsNonSigner() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, "");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.NotSigner.selector, outsider));
        ms.revoke(id);
    }

    function test_cancel_rejectsNonSigner() public {
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, "");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.NotSigner.selector, outsider));
        ms.cancel(id);
    }

    // ════════════════════════════ Cancel mechanism ═════════════════════════════

    function test_cancel_anySingleSignerCanAbort() public {
        uint256 id = _submitAndFullyConfirm(address(mock), 0, abi.encodeCall(MockTarget.ping, (99)));
        vm.prank(s2);
        ms.cancel(id);
        (, , , , , bool ex, bool cancelled) = ms.getProposal(id);
        assertFalse(ex);
        assertTrue(cancelled);

        // Execute now reverts
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyCancelled.selector, id));
        ms.execute(id);

        // Confirm / revoke also reject
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyCancelled.selector, id));
        ms.revoke(id);

        // Cannot cancel twice
        vm.prank(s3);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyCancelled.selector, id));
        ms.cancel(id);
    }

    function test_cancel_revertsAfterExecute() public {
        uint256 id = _submitAndFullyConfirm(address(mock), 0, abi.encodeCall(MockTarget.ping, (1)));
        ms.execute(id);
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyExecuted.selector, id));
        ms.cancel(id);
    }

    // ════════════════════════════ Post-execute states ══════════════════════════

    function test_confirm_revertsAfterExecute() public {
        uint256 id = _submitAndFullyConfirm(address(mock), 0, abi.encodeCall(MockTarget.ping, (1)));
        ms.execute(id);
        // Cannot confirm after execute. Contract checks executed BEFORE
        // double-confirm, so AlreadyExecuted fires first even though s1 also
        // already confirmed during submit.
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.AlreadyExecuted.selector, id));
        ms.confirm(id);
    }

    function test_unknownProposalId_revertsProposalNotFound() public {
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.ProposalNotFound.selector, 9999));
        ms.confirm(9999);
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.ProposalNotFound.selector, 9999));
        ms.revoke(9999);
        vm.prank(s1);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.ProposalNotFound.selector, 9999));
        ms.cancel(9999);
        vm.expectRevert(abi.encodeWithSelector(AdminMultiSig.ProposalNotFound.selector, 9999));
        ms.execute(9999);
    }

    // ════════════════════════════ Target revert propagation ════════════════════

    function test_targetRevert_propagatesAndAllowsRetry() public {
        mock.setRevert(true);
        uint256 id = _submitAndFullyConfirm(address(mock), 0, abi.encodeCall(MockTarget.ping, (1)));

        vm.expectRevert(); // CallFailed wraps the inner revert
        ms.execute(id);

        // Because the whole tx reverted, executed=false is preserved → retry possible
        (, , , , , bool ex, ) = ms.getProposal(id);
        assertFalse(ex);

        // Fix the target and retry
        mock.setRevert(false);
        ms.execute(id);
        assertEq(mock.lastArg(), 1);
    }

    // ════════════════════════════ Self-call attack ═════════════════════════════

    function test_selfCall_rejectedByOnlySigner() public {
        // Attempt: propose calling multisig.submit() itself; when executed,
        // msg.sender to inner submit() is the multisig contract (not a signer),
        // so onlySigner fires.
        bytes memory innerCall = abi.encodeCall(
            AdminMultiSig.submit, (address(mock), 0, abi.encodeCall(MockTarget.ping, (1)))
        );
        uint256 id = _submitAndFullyConfirm(address(ms), 0, innerCall);
        vm.expectRevert(); // CallFailed (inner NotSigner)
        ms.execute(id);
    }

    // ════════════════════════════ Native value forwarding ══════════════════════

    function test_executeForwardsNativeValue() public {
        // Fund multisig with 1 ether
        vm.deal(address(ms), 1 ether);
        uint256 id = _submitAndFullyConfirm(
            address(mock), 0.3 ether, abi.encodeCall(MockTarget.ping, (5))
        );
        ms.execute(id);
        assertEq(mock.lastValue(), 0.3 ether);
        assertEq(address(ms).balance, 0.7 ether);
    }

    function test_receivesNativeViaPlainSend() public {
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        (bool ok, ) = address(ms).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(ms).balance, 0.5 ether);
    }

    // ════════════════════════════ Events ═══════════════════════════════════════

    function test_eventsEmittedCorrectly() public {
        bytes memory data = abi.encodeCall(MockTarget.ping, (42));

        vm.expectEmit(true, true, true, true);
        emit ProposalCreated(1, s1, address(mock), 0, data);
        vm.expectEmit(true, true, false, true);
        emit ProposalConfirmed(1, s1, 1);
        vm.prank(s1);
        uint256 id = ms.submit(address(mock), 0, data);

        vm.expectEmit(true, true, false, true);
        emit ProposalConfirmed(id, s2, 2);
        vm.prank(s2); ms.confirm(id);

        vm.expectEmit(true, true, false, true);
        emit ProposalRevoked(id, s2, 1);
        vm.prank(s2); ms.revoke(id);

        vm.prank(s2); ms.confirm(id);
        vm.prank(s3); ms.confirm(id);

        vm.expectEmit(true, true, false, false);
        emit ProposalExecuted(id, address(this), "");
        ms.execute(id);
    }
}
