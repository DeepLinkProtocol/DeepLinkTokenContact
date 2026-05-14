// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DLC v2 — DeepLink Coin (full v1 preservation + admin force-transfer)
/// @notice UUPS upgrade for proxy 0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe.
///
/// ──────────────────────────── Design constraints ───────────────────────────────
/// v1 source (`docs/v1-source/DLC.sol`) declares 8 sequential storage variables
/// at slots 0..7 (`timeLock`+`isLockActive` packed at slot 0, `walletLockTimestamp`
/// at slot 1, `initSupply`/`maxSupply` at 2/3, two mappings at 4/5,
/// `canUpgradeAddress` at slot 6, `disableUpgrade` at slot 7). v2 MUST declare
/// these in the EXACT same order to preserve binary-compatible storage layout.
///
/// v1 ALSO clears `canUpgradeAddress = address(0)` at the end of
/// `_authorizeUpgrade`. That clear happens BEFORE the delegatecall to
/// `initializeV2(...)`, so `initializeV2` MUST NOT gate on
/// `msg.sender == canUpgradeAddress` (slot 6 is already 0 by then). Replay
/// protection is provided by `reinitializer(2)` alone; the atomicity of
/// `upgradeToAndCall(impl, init)` ensures no front-running window because the
/// only way to reach `initializeV2` is via a successful upgrade tx, which is
/// gated by v1's slot-6 check.
///
/// v2's own `_authorizeUpgrade` (for future v3 etc.) also clears
/// `canUpgradeAddress`, preserving v1's "one-time-grant per upgrade" model.
///
/// ──────────────────────────── New v2 capabilities ──────────────────────────────
///   - admin / setAdmin: a single admin slot, settable by the existing
///     MultiSigTimeLock contract (same governance pattern as v1's other admin
///     operations). Initial admin is set atomically in `initializeV2(admin_)`.
///   - forceTransfer(from, to, amount): admin can move tokens between any two
///     wallets without the holder's signature. Bypasses both ERC20 allowance
///     AND the lock check (locked tokens can still be moved for recovery).
///     Emits standard Transfer event + audit ForceTransfer event.
///   - rescueOtherTokens(token, to, amount): admin can recover non-DLC ERC20
///     tokens accidentally sent to the proxy. Emits Rescued event.
///
/// All v1 functions are preserved verbatim (transfer/transferFrom/burn with
/// lock checks, transferAndLock, getLockInfos, getAvailableAmount,
/// calculateLockedAmount, setUpgradePermission, disableContractUpgrade,
/// disableLockPermanently/enableLockPermanently, updateLockDuration,
/// addLockTransferAdmin/removeLockTransferAdmin, withdrawDLCTo) — see the
/// "v1 preserved functions" section below.
///
/// ──────────────────────────── Operational recommendations ──────────────────────
/// • Initial admin set in `initializeV2(admin_)` SHOULD be a multisig
///   (e.g. Safe). Force-transfer has no built-in rate limit; one EOA
///   compromise = catastrophic asset loss.
/// • Admin rotation (`setAdmin`) — TWO callers allowed (Option A):
///     1. Current admin — instant self-rotation, no delay. Primary path for
///        routine ops (Safe → Safe migrations).
///     2. MultiSigTimeLock (slot 0 `timeLock`) — ~24h emergency rescue when
///        admin keys are lost/stuck. NOT the primary rotation path.
///   Operational caveats:
///     - setAdmin reverts on address(0), address(this), and precompiles
///       (≤ 0xff). Other typos (e.g. dead EOAs) are NOT caught — only
///       timeLock rescue can recover. Use a 2-step propose/accept off-chain
///       process before broadcasting setAdmin from the admin Safe.
///     - Setting admin == timeLock collapses operational separation and
///       turns every forceTransfer into a 24h timeLock proposal — avoid.
/// • Off-chain monitoring MUST subscribe to AdminChanged + ForceTransfer +
///   Rescued events and alert on every emission. AdminChanged with prev==0
///   fires once during initializeV2 — whitelist by tx hash, NOT by prev==0.
contract DLCv2 is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────── v1 storage (slots 0..7, MUST NOT CHANGE ORDER) ─────────────

    /// @notice MultiSigTimeLock contract (slot 0, packed with isLockActive).
    /// Stored as `address` not `MultiSigTimeLock` to avoid pulling the
    /// full v1 contract source as a dependency; ABI return type changes from
    /// `MultiSigTimeLock` to `address` but binary layout and storage are
    /// unchanged (still a 20-byte address at the same slot).
    address public timeLock;             // slot 0

    bool public isLockActive;            // slot 0 packed

    struct LockInfo {
        uint256 lockedAt;
        uint256 lockedAmount;
        uint256 unlockAt;
    }

    mapping(address => LockInfo[]) private walletLockTimestamp;  // slot 1

    uint256 public initSupply;           // slot 2
    uint256 public maxSupply;            // slot 3

    mapping(address => uint256) public minter2MintAmount;  // slot 4
    mapping(address => bool) public lockTransferAdmins;    // slot 5

    address public canUpgradeAddress;    // slot 6
    bool public disableUpgrade;          // slot 7

    // ──────────────── v2-only storage in ERC-7201 namespace ─────────────────────
    /// @custom:storage-location erc7201:deeplink.dlc.v2
    struct DLCv2Storage {
        address admin;                  // can call forceTransfer / rescueOtherTokens
        uint256 forceTransferCount;     // counter for off-chain audit
    }

    // keccak256(abi.encode(uint256(keccak256("deeplink.dlc.v2")) - 1)) & ~bytes32(uint256(0xff))
    // Verified by `test_namespace_slot_matches_formula` + Python eth_hash.
    bytes32 private constant DLC_V2_STORAGE_LOCATION =
        0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400;

    function _getDLCv2Storage() private pure returns (DLCv2Storage storage $) {
        assembly {
            $.slot := DLC_V2_STORAGE_LOCATION
        }
    }

    // ───────────────────────────── Custom errors ────────────────────────────────
    error NotAdmin(address caller);
    error NotAdminOrTimeLock(address caller);
    error ZeroAddress();
    error InvalidAmount();
    error TransferToSelf();
    error CannotRescueDLC();
    error CannotTouchProxy();
    error InvalidAdmin(address attempted);

    // ────────────────────────── v1 events (preserved) ───────────────────────────
    event LockDisabled(uint256 timestamp, uint256 blockNumber);
    event LockEnabled(uint256 timestamp, uint256 blockNumber);
    event TransferAndLock(address indexed from, address indexed to, uint256 value, uint256 blockNumber);
    event UpdateLockDuration(address indexed wallet, uint256 lockSeconds);
    event AddLockTransferAdmin(address indexed addr);
    event RemoveLockTransferAdmin(address indexed addr);
    event AuthorizedUpgradeSelf(address indexed canUpgradeAddress);
    event DisableContractUpgrade(uint256 timestamp);
    event WithdrawDLC(address indexed to, uint256 amount);

    // ─────────────────────────────── v2 events ──────────────────────────────────
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event ForceTransfer(
        address indexed admin,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 indexCounter
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────── Modifiers ──────────────────────────────────
    modifier onlyLockTransferAdmin() {
        require(lockTransferAdmins[msg.sender], "Not lock transfer admin");
        _;
    }

    modifier onlyMultiSigTimeLockContract() {
        require(msg.sender == timeLock, "Not multi sig time lock contract");
        _;
    }

    modifier onlyAdmin() {
        address a = _getDLCv2Storage().admin;
        if (msg.sender != a) revert NotAdmin(msg.sender);
        _;
    }

    /// Allows either the current admin OR the MultiSigTimeLock to act. Used
    /// only by `setAdmin` so admin can self-rotate (instant) without giving
    /// up the timeLock-based emergency recovery path (24h+ via MultiSig).
    modifier onlyAdminOrTimeLock() {
        if (msg.sender != _getDLCv2Storage().admin && msg.sender != timeLock) {
            revert NotAdminOrTimeLock(msg.sender);
        }
        _;
    }

    // ───────────────────────────── Constructor ──────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─────────────────────────── v2 initializer ─────────────────────────────────

    /// Atomic post-upgrade initialization. Sets the initial v2 admin in the
    /// SAME tx as `upgradeToAndCall`, eliminating any window where the proxy
    /// is upgraded but admin is unset.
    ///
    /// Access control: ONLY `reinitializer(2)`. We deliberately do NOT gate
    /// on canUpgradeAddress, because v1's `_authorizeUpgrade` clears slot 6
    /// to address(0) BEFORE the delegatecall to this function — meaning any
    /// canUpgradeAddress-based check would always fail here.
    ///
    /// Safety analysis for the lack of explicit access control:
    ///   - Before upgrade: proxy points to v1, which has no initializeV2
    ///     selector → direct call reverts on fallback.
    ///   - During upgrade: the only path to reach this function is via
    ///     `upgradeToAndCall(impl, initializeV2(admin))` atomically, which
    ///     is gated by v1's _authorizeUpgrade (slot 6 check). No front-run
    ///     window exists because the call is inside a single tx.
    ///   - After upgrade: reinitializer(2) is consumed → revert on replay.
    ///   - On v2 impl directly (not via proxy): `_disableInitializers()` in
    ///     constructor sets `_initialized = type(uint64).max` → revert.
    function initializeV2(address initialAdmin) external reinitializer(2) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        DLCv2Storage storage $ = _getDLCv2Storage();
        $.admin = initialAdmin;
        emit AdminChanged(address(0), initialAdmin);
    }

    // ────────────── UUPS upgrade gate (matches v1 semantics) ────────────────────

    /// Same access checks as v1: requires disableUpgrade==false + msg.sender
    /// is the current canUpgradeAddress + non-zero new impl, then CLEARS
    /// canUpgradeAddress (one-time-grant model). Future upgrades require
    /// MultiSigTimeLock to call setUpgradePermission again.
    function _authorizeUpgrade(address newImplementation) internal override {
        require(disableUpgrade == false, "Has disabled upgrade");
        require(msg.sender == canUpgradeAddress, "Only canUpgradeAddress can upgrade");
        require(newImplementation != address(0), "Invalid implementation address");
        canUpgradeAddress = address(0);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // v1 preserved functions (identical behaviour, identical signatures)
    // ════════════════════════════════════════════════════════════════════════════

    // ─────────────────── Override: transfer / transferFrom / burn ───────────────

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (to == address(0) || amount == 0) {
            return super.transfer(to, amount);
        }
        if (isLockActive && walletLockTimestamp[msg.sender].length > 0) {
            require(canTransferAmount(msg.sender, amount), "Insufficient unlocked balance");
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (to == address(0) || amount == 0) {
            return super.transferFrom(from, to, amount);
        }
        if (isLockActive && walletLockTimestamp[from].length > 0) {
            require(canTransferAmount(from, amount), "Insufficient unlocked balance");
        }
        return super.transferFrom(from, to, amount);
    }

    function burn(uint256 amount) public virtual override {
        if (isLockActive && walletLockTimestamp[msg.sender].length > 0) {
            require(canTransferAmount(msg.sender, amount), "Insufficient unlocked balance");
        }
        super.burn(amount);
    }

    // ───────────────────────────── Lock views ───────────────────────────────────

    function canTransferAmount(address from, uint256 transferAmount) internal view returns (bool) {
        uint256 lockedAmount = calculateLockedAmount(from);
        uint256 availableAmount = balanceOf(from) - lockedAmount;
        return availableAmount >= transferAmount;
    }

    function calculateLockedAmount(address from) public view returns (uint256) {
        LockInfo[] storage lockInfos = walletLockTimestamp[from];
        uint256 lockedAmount = 0;
        for (uint256 i = 0; i < lockInfos.length; i++) {
            if (block.timestamp < lockInfos[i].unlockAt) {
                lockedAmount += lockInfos[i].lockedAmount;
            }
        }
        return lockedAmount;
    }

    function getAvailableAmount(address caller) public view returns (uint256, uint256) {
        uint256 lockedAmount = calculateLockedAmount(caller);
        uint256 total = balanceOf(caller);
        uint256 availableAmount = total - lockedAmount;
        return (total, availableAmount);
    }

    function getLockAmountAndUnlockAt(address caller, uint16 index) public view returns (uint256, uint256) {
        require(index < walletLockTimestamp[caller].length, "Index out of range");
        LockInfo memory lockInfo = walletLockTimestamp[caller][index];
        return (lockInfo.lockedAmount, lockInfo.unlockAt);
    }

    function getLockInfos(address caller) public view returns (LockInfo[] memory) {
        return walletLockTimestamp[caller];
    }

    // ───────────────────────── Lock transfer admin ──────────────────────────────

    function transferAndLock(address to, uint256 value, uint256 lockSeconds) external onlyLockTransferAdmin {
        require(lockSeconds > 0, "Invalid lock duration");
        uint256 lockedAt = block.timestamp;
        uint256 unLockAt = lockedAt + lockSeconds;

        LockInfo[] storage infos = walletLockTimestamp[to];
        require(infos.length < 100, "Too many lock entries");

        infos.push(LockInfo(lockedAt, value, unLockAt));
        transfer(to, value);

        emit TransferAndLock(msg.sender, to, value, block.number);
    }

    // ───────────────────────── MultiSigTimeLock gated ───────────────────────────

    function requestSetUpgradePermission(address _canUpgradeAddress) external pure returns (bytes memory) {
        return abi.encodeWithSignature("setUpgradePermission(address)", _canUpgradeAddress);
    }

    function setUpgradePermission(address _canUpgradeAddress) external onlyMultiSigTimeLockContract {
        require(disableUpgrade == false, "Contract upgrade is disabled");
        require(_canUpgradeAddress != address(0), "Invalid address");
        canUpgradeAddress = _canUpgradeAddress;
        emit AuthorizedUpgradeSelf(_canUpgradeAddress);
    }

    function requestDisableContractUpgrade() external pure returns (bytes memory) {
        return abi.encodeWithSignature("disableContractUpgrade()");
    }

    function disableContractUpgrade() external onlyMultiSigTimeLockContract {
        disableUpgrade = true;
        emit DisableContractUpgrade(block.timestamp);
    }

    function requestDisableLockPermanently() external pure returns (bytes memory) {
        return abi.encodeWithSignature("disableLockPermanently()");
    }

    function disableLockPermanently() external onlyMultiSigTimeLockContract {
        isLockActive = false;
        emit LockDisabled(block.timestamp, block.number);
    }

    function requestEnableLockPermanently() external pure returns (bytes memory) {
        return abi.encodeWithSignature("enableLockPermanently()");
    }

    function enableLockPermanently() external onlyMultiSigTimeLockContract {
        isLockActive = true;
        emit LockEnabled(block.timestamp, block.number);
    }

    function requestUpdateLockDuration(address wallet, uint256 lockSeconds) external pure returns (bytes memory) {
        return abi.encodeWithSignature("updateLockDuration(address,uint256)", wallet, lockSeconds);
    }

    function updateLockDuration(address wallet, uint256 lockSeconds) external onlyMultiSigTimeLockContract {
        LockInfo[] storage lockInfos = walletLockTimestamp[wallet];
        for (uint256 i = 0; i < lockInfos.length; i++) {
            lockInfos[i].unlockAt = lockInfos[i].lockedAt + lockSeconds;
        }
        emit UpdateLockDuration(wallet, lockSeconds);
    }

    function requestAddLockTransferAdmin(address addr) external pure returns (bytes memory) {
        return abi.encodeWithSignature("addLockTransferAdmin(address)", addr);
    }

    function requestRemoveLockTransferAdmin(address addr) external pure returns (bytes memory) {
        return abi.encodeWithSignature("removeLockTransferAdmin(address)", addr);
    }

    function addLockTransferAdmin(address addr) external onlyMultiSigTimeLockContract {
        lockTransferAdmins[addr] = true;
        emit AddLockTransferAdmin(addr);
    }

    function removeLockTransferAdmin(address addr) external onlyMultiSigTimeLockContract {
        lockTransferAdmins[addr] = false;
        emit RemoveLockTransferAdmin(addr);
    }

    // ────────────────────────── withdrawDLCTo (v1) ──────────────────────────────

    /// Preserved from v1 verbatim. Only the hardcoded controller wallet
    /// (0x36Ede4Fe...) can pull DLC held by the proxy itself.
    ///
    /// Note: forceTransfer CANNOT move tokens out of the proxy itself —
    /// `CannotTouchProxy` blocks `from == address(this)` / `to == address(this)`
    /// (see line 457). withdrawDLCTo is therefore the SOLE path for proxy-held
    /// DLC. The 0x36Ede4Fe... recipient is a v1 immutable that v2 preserves
    /// verbatim; if that key is compromised, admin/forceTransfer cannot prevent
    /// withdrawal. Operators should monitor `WithdrawDLC` events accordingly.
    function withdrawDLCTo(address to, uint256 amount) external {
        require(msg.sender == address(0x36Ede4Fe3CD9F270747f07c15D8098F10dF6D8e8), "has no permission");
        DLCv2(address(this)).transfer(to, amount);
        emit WithdrawDLC(to, amount);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // v2 new functions (forceTransfer, admin management, rescue)
    // ════════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────── Admin views ────────────────────────────────

    function admin() external view returns (address) {
        return _getDLCv2Storage().admin;
    }

    function forceTransferCount() external view returns (uint256) {
        return _getDLCv2Storage().forceTransferCount;
    }

    // ───────────────────────────── Admin rotation ───────────────────────────────

    /// Helper to build calldata for either path:
    ///   - current admin (instant self-rotation via direct call), OR
    ///   - the MultiSigTimeLock proposal flow (24h+ emergency rescue).
    /// Pure / no state change; safe to call off-chain.
    function requestSetAdmin(address newAdmin) external pure returns (bytes memory) {
        return abi.encodeWithSignature("setAdmin(address)", newAdmin);
    }

    /// Rotates the v2 admin. TWO callers are allowed:
    ///   1. Current admin — instant self-rotation. Useful for routine ops or
    ///      when admin is a Safe multisig that wants to migrate to a new Safe.
    ///   2. MultiSigTimeLock (`timeLock` at slot 0) — slow (~24h) recovery
    ///      path when admin keys are lost / stuck.
    ///
    /// Sanity-guards (revert with InvalidAdmin):
    ///   - newAdmin == address(this): the proxy can never originate a tx, so
    ///     this would brick admin rotation until a timeLock 24h rescue.
    ///   - newAdmin in the precompile range (0x1..0xff): no signing key on any
    ///     EVM chain; same brick result. Cheaply blocks fat-finger typos.
    ///
    /// Security note: allowing admin self-rotation does NOT increase attack
    /// surface meaningfully. A compromised admin can already drain via
    /// forceTransfer; the extra ability to lock-out by rotating to attacker's
    /// own address is mitigated by:
    ///   - admin MUST be a multisig (enforced by deploy script)
    ///   - MultiSigTimeLock retains 24h emergency override
    ///   - Off-chain ForceTransfer event monitoring with auto-alert
    function setAdmin(address newAdmin) external onlyAdminOrTimeLock {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (newAdmin == address(this)) revert InvalidAdmin(newAdmin);
        if (uint160(newAdmin) <= 0xff) revert InvalidAdmin(newAdmin);
        DLCv2Storage storage $ = _getDLCv2Storage();
        address prev = $.admin;
        $.admin = newAdmin;
        emit AdminChanged(prev, newAdmin);
    }

    // ────────────────────────────── forceTransfer ───────────────────────────────

    /// Admin-only forced movement of tokens between two wallets. Uses the
    /// internal `_update` path so a normal Transfer event is emitted and
    /// downstream indexers record it as a regular transfer.
    ///
    /// IMPORTANT: forceTransfer BYPASSES BOTH allowance AND the lock check.
    /// This is intentional — recovery scenarios (stolen funds, mis-sent
    /// addresses, regulatory seizure) must work regardless of lock state.
    ///
    /// Reverts on:
    ///   - non-admin caller (NotAdmin)
    ///   - from or to == address(0) (ZeroAddress)
    ///   - from or to == address(this) (CannotTouchProxy) — proxy's own DLC
    ///     balance moves through withdrawDLCTo only, to keep audit signals
    ///     clean (ForceTransfer events that touch the proxy are otherwise an
    ///     obvious obfuscation channel)
    ///   - amount == 0 (InvalidAmount)
    ///   - from == to (TransferToSelf)
    ///   - insufficient balance on `from` (ERC20InsufficientBalance, inherited)
    function forceTransfer(address from, address to, uint256 amount)
        external
        onlyAdmin
        nonReentrant
    {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (from == address(this) || to == address(this)) revert CannotTouchProxy();
        if (amount == 0) revert InvalidAmount();
        if (from == to) revert TransferToSelf();

        DLCv2Storage storage $ = _getDLCv2Storage();
        unchecked { $.forceTransferCount += 1; }

        // _update does the balance bookkeeping + emits Transfer.
        // Bypasses allowance AND lock checks (the whole point).
        _update(from, to, amount);

        emit ForceTransfer(msg.sender, from, to, amount, $.forceTransferCount);
    }

    // ──────────────────────────── rescueOtherTokens ─────────────────────────────

    /// Admin-only recovery of NON-DLC ERC20 tokens accidentally sent to this
    /// contract address. DLC itself is recovered via forceTransfer (see notes
    /// on forceTransfer above).
    function rescueOtherTokens(address token, address to, uint256 amount)
        external
        onlyAdmin
        nonReentrant
    {
        if (token == address(this)) revert CannotRescueDLC();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
