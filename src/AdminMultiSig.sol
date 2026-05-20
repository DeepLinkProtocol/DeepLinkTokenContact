// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AdminMultiSig — minimal 3-of-3 multisig for DLC v2 admin
/// @notice IMMUTABLE 3 signers. Any signer can submit a proposal calling any
///         target contract with any calldata + value. Execution requires
///         confirmations from ALL 3 signers (n-of-n threshold).
///
/// Design notes:
///   - Signers are constructor-immutable. There is NO function to change them.
///     Losing 1 of 3 keys = permanently bricked admin → recovery requires DBC
///     MultiSigTimeLock to call DLCv2.setAdmin(newAdmin) (~24h rescue).
///   - No nonce-based replay risk: each proposal has its own id and one-shot
///     `executed` flag. Same calldata can be re-proposed as a NEW proposal id.
///   - Per-signer revocation supported BEFORE execution to recover from
///     mistakes during the confirmation window.
///   - Re-entrancy guarded on execute() (target may call back into this
///     multisig but cannot re-execute the same proposal).
///   - Native value forwarding supported; multisig can hold native gas token.
///
/// Threat model:
///   - 1 signer compromised: attacker cannot execute (needs 3-of-3).
///   - 2 signers compromised: attacker cannot execute (needs 3-of-3).
///   - 3 signers compromised: catastrophic. No recovery from this multisig
///     itself; the DLC v2 timeLock (`MultiSigTimeLock` 0x3ffc1eac...) can
///     setAdmin to a new safe address with 24h delay.
contract AdminMultiSig is ReentrancyGuard {
    address public immutable signer1;
    address public immutable signer2;
    address public immutable signer3;

    uint256 public constant THRESHOLD = 3;

    struct Proposal {
        address target;
        uint256 value;
        bytes   data;
        uint64  createdAt;
        uint8   confirmCount;     // 0..3
        bool    executed;
        bool    cancelled;        // any 1 signer can emergency-abort before execute
        mapping(address => bool) confirmed;
    }

    /// Monotonically increasing proposal id. Starts at 1 (0 reserved for "none").
    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) private proposals;

    // ───────────────────────────── Custom errors ────────────────────────────────
    error NotSigner(address caller);
    error DuplicateSigner();
    error ZeroSigner();
    error ProposalNotFound(uint256 id);
    error AlreadyConfirmed(uint256 id, address signer);
    error NotConfirmed(uint256 id, address signer);
    error AlreadyExecuted(uint256 id);
    error AlreadyCancelled(uint256 id);
    error InsufficientConfirmations(uint256 id, uint8 have, uint256 need);
    error CallFailed(uint256 id, bytes returnData);

    // ─────────────────────────────── Events ────────────────────────────────────
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes   data
    );
    event ProposalConfirmed(uint256 indexed id, address indexed signer, uint8 confirmCount);
    event ProposalRevoked(uint256 indexed id, address indexed signer, uint8 confirmCount);
    event ProposalCancelled(uint256 indexed id, address indexed canceller);
    event ProposalExecuted(uint256 indexed id, address indexed executor, bytes returnData);

    // ─────────────────────────────── Modifiers ──────────────────────────────────
    modifier onlySigner() {
        if (msg.sender != signer1 && msg.sender != signer2 && msg.sender != signer3) {
            revert NotSigner(msg.sender);
        }
        _;
    }

    // ─────────────────────────────── Constructor ────────────────────────────────
    /// @param s1 First signer EOA
    /// @param s2 Second signer EOA
    /// @param s3 Third signer EOA
    /// Reverts if any signer is the zero address or if any two signers are equal.
    constructor(address s1, address s2, address s3) {
        if (s1 == address(0) || s2 == address(0) || s3 == address(0)) revert ZeroSigner();
        if (s1 == s2 || s1 == s3 || s2 == s3) revert DuplicateSigner();
        signer1 = s1;
        signer2 = s2;
        signer3 = s3;
    }

    // ─────────────────────────── Submit + auto-confirm ──────────────────────────
    /// Submit a new proposal AND auto-confirm it on behalf of `msg.sender`.
    /// Returns the proposal id. Caller must be a signer.
    function submit(address target, uint256 value, bytes calldata data)
        external
        onlySigner
        returns (uint256 id)
    {
        id = nextProposalId++;
        Proposal storage p = proposals[id];
        p.target    = target;
        p.value     = value;
        p.data      = data;
        p.createdAt = uint64(block.timestamp);
        // Submitter implicitly confirms
        p.confirmed[msg.sender] = true;
        p.confirmCount = 1;

        emit ProposalCreated(id, msg.sender, target, value, data);
        emit ProposalConfirmed(id, msg.sender, 1);
    }

    // ─────────────────────────────── Confirm ────────────────────────────────────
    /// Additional signer confirmation. Auto-rejects double-confirm, post-execution
    /// and cancelled proposals.
    function confirm(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0)        revert ProposalNotFound(id);
        if (p.executed)              revert AlreadyExecuted(id);
        if (p.cancelled)             revert AlreadyCancelled(id);
        if (p.confirmed[msg.sender]) revert AlreadyConfirmed(id, msg.sender);
        p.confirmed[msg.sender] = true;
        unchecked { p.confirmCount += 1; }
        emit ProposalConfirmed(id, msg.sender, p.confirmCount);
    }

    // ─────────────────────────── Revoke (before execute) ────────────────────────
    /// A signer who confirmed can revoke their confirmation BEFORE execution.
    /// Cancelled proposals reject revoke (use cancel state instead).
    function revoke(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0)         revert ProposalNotFound(id);
        if (p.executed)               revert AlreadyExecuted(id);
        if (p.cancelled)              revert AlreadyCancelled(id);
        if (!p.confirmed[msg.sender]) revert NotConfirmed(id, msg.sender);
        p.confirmed[msg.sender] = false;
        unchecked { p.confirmCount -= 1; }
        emit ProposalRevoked(id, msg.sender, p.confirmCount);
    }

    // ───────────────────────────── Cancel (emergency) ───────────────────────────
    /// Any single signer can emergency-cancel a proposal BEFORE it is executed.
    /// Useful when a typo / wrong calldata is detected after 3-of-3 has confirmed
    /// but before execute() lands. After cancel, the proposal is dead forever;
    /// re-propose by calling submit() with corrected calldata (new id).
    function cancel(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound(id);
        if (p.executed)       revert AlreadyExecuted(id);
        if (p.cancelled)      revert AlreadyCancelled(id);
        p.cancelled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    // ─────────────────────────────── Execute ────────────────────────────────────
    /// Execute the proposal once THRESHOLD (3) confirmations are gathered.
    /// PERMISSIONLESS: any caller can pay gas to execute once 3-of-3 has signed
    /// (the 3 confirmations ARE the authorization; the executor is just a relay).
    /// Re-entrancy guarded: a malicious target cannot re-enter to execute again
    /// because the `executed` flag is set BEFORE the external call.
    function execute(uint256 id) external nonReentrant returns (bytes memory) {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert ProposalNotFound(id);
        if (p.executed)       revert AlreadyExecuted(id);
        if (p.cancelled)      revert AlreadyCancelled(id);
        if (p.confirmCount < THRESHOLD) {
            revert InsufficientConfirmations(id, p.confirmCount, THRESHOLD);
        }
        p.executed = true; // CEI: mark before external call

        (bool ok, bytes memory ret) = p.target.call{value: p.value}(p.data);
        if (!ok) revert CallFailed(id, ret);

        emit ProposalExecuted(id, msg.sender, ret);
        return ret;
    }

    // ───────────────────────────────── Views ────────────────────────────────────
    function getProposal(uint256 id) external view returns (
        address target,
        uint256 value,
        bytes   memory data,
        uint64  createdAt,
        uint8   confirmCount,
        bool    executed,
        bool    cancelled
    ) {
        Proposal storage p = proposals[id];
        return (p.target, p.value, p.data, p.createdAt, p.confirmCount, p.executed, p.cancelled);
    }

    function hasConfirmed(uint256 id, address who) external view returns (bool) {
        return proposals[id].confirmed[who];
    }

    function signers() external view returns (address, address, address) {
        return (signer1, signer2, signer3);
    }

    function isSigner(address who) external view returns (bool) {
        return who == signer1 || who == signer2 || who == signer3;
    }

    // ────────────────────────────── Native receive ──────────────────────────────
    /// Allow the multisig to hold native gas token (e.g. for refunds).
    receive() external payable {}
}
