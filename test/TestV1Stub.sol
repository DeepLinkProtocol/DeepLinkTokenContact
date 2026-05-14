// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title TestV1Stub — minimal v1-like contract for end-to-end DLCv2 testing
/// @notice MATCHES real v1 storage layout (slots 0-7) AND _authorizeUpgrade
///         behaviour (clears canUpgradeAddress). Has an extra helper
///         `setCanUpgradeAddressDirect` so tests can grant upgrade permission
///         without needing a MultiSigTimeLock.
///
/// THIS IS A TEST-ONLY CONTRACT. Do NOT use as production DLC.
contract TestV1Stub is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // v1 layout slots 0-7 (MUST match real v1 + DLCv2)
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Test initializer: sets up state matching real v1 patterns, mints 1M
    /// test tokens to initialOwner.
    function initialize(address initialOwner, address timeLockAddr) public initializer {
        __ERC20_init("TestDLC", "TDLC");
        __ReentrancyGuard_init();
        __ERC20Permit_init("TestDLC");
        __ERC20Burnable_init();
        __UUPSUpgradeable_init();

        initSupply = 1_000_000 * 10 ** decimals();
        maxSupply = initSupply;
        _mint(initialOwner, initSupply);
        isLockActive = true;
        timeLock = timeLockAddr;
    }

    /// Test helper: anyone can set canUpgradeAddress (simplification — real v1
    /// requires MultiSigTimeLock). DOES NOT EXIST in production v1.
    function setCanUpgradeAddressDirect(address a) external {
        canUpgradeAddress = a;
    }

    /// MIRRORS REAL v1: clears slot 6 after passing the upgrade gate.
    function _authorizeUpgrade(address newImplementation) internal override {
        require(disableUpgrade == false, "Has disabled upgrade");
        require(msg.sender == canUpgradeAddress, "Only canUpgradeAddress can upgrade");
        require(newImplementation != address(0), "Invalid implementation address");
        canUpgradeAddress = address(0);
    }
}
