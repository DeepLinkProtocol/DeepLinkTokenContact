// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Token is Initializable, ERC20Upgradeable, OwnableUpgradeable, ERC20PermitUpgradeable, ERC20BurnableUpgradeable {
    using SafeERC20 for IERC20;
    bool public isLockActive;

    struct LockInfo {
        uint256 lockedAt;
        uint256 lockedAmount;
        uint256 unlockAt;
    }

    mapping(address => LockInfo[]) walletLockBlock;
    address[] public lockTransferAdmins;

    uint256 public  initSupply;
    uint256 public  maxSupply;
    uint256 public alreadyMinted;
    uint256 public supplyForStaking;
    uint256 public supplyForOrionStaking;


    mapping(address => uint256) public minter2MintAmount;
    mapping(address => bool) public burners;


    event LockDisabled(uint256 timestamp, uint256 blockNumber);
    event LockEnabled(uint256 timestamp, uint256 blockNumber);

    event TransferAndLock(
        address indexed from,
        address indexed to,
        uint256 value,
        uint256 blockNumber
    );
    event UpdateLockBlock(address indexed wallet, uint256 blockNumber);

    modifier onlyOwnerOrLockTransferAdmin() {
        bool isOwner = msg.sender == super.owner();
        bool isAdmin = false;
        for (uint16 i = 0; i < lockTransferAdmins.length; i++) {
            if (msg.sender == lockTransferAdmins[i]) {
                isAdmin = true;
                break;
            }
        }
        require(isOwner || isAdmin, "not owner or lock transfer admin");
        _;
    }

    function initialize(address initialOwner) public initializer {
        __ERC20_init("DeepLink", "DLC");
        __Ownable_init(initialOwner);

        maxSupply = 90_000_000_000 * 10 ** decimals();
        supplyForStaking = 20_000_000_000 * 10 ** decimals();
        supplyForOrionStaking = 3_000_000_000 * 10 ** decimals();
        initSupply = maxSupply - supplyForStaking - supplyForOrionStaking;
        alreadyMinted = initSupply;

        _mint(owner(), initSupply);
        isLockActive = true;
    }

    function setMinter(address minter, uint256 amount) public onlyOwner {
        require(amount <= maxSupply - alreadyMinted, "max supply reached");
        minter2MintAmount[minter] = amount;
    }

    function mint(address to, uint256 amount) external {
        uint256 totalAmount = minter2MintAmount[msg.sender];
        require(totalAmount >= amount , "can not mint");
        require(alreadyMinted + amount <= maxSupply, "max supply reached");
        _mint(to, amount);
        minter2MintAmount[msg.sender] = totalAmount - amount;
        alreadyMinted += amount;
    }

    function setBurner(address burner)  public onlyOwner{
        burners[burner] = true;
    }

    function burn(uint256 value) public override {
        require(burners[msg.sender], "not a valid burner");
        super.burn(value);
    }


    function claimStuckTokens(address token) external onlyOwner {
        IERC20 ERC20token = IERC20(token);
        uint256 balance = ERC20token.balanceOf(address(this));
        ERC20token.safeTransfer(msg.sender, balance);
    }

    function disableLockPermanently() external onlyOwner {
        isLockActive = false;

        emit LockDisabled(block.timestamp, block.number);
    }

    function enableLockPermanently() external onlyOwner {
        isLockActive = true;

        emit LockEnabled(block.timestamp, block.number);
    }

    function updateLockBlock(
        address wallet,
        uint256 blockNumber
    ) external onlyOwner {
        LockInfo[] storage lockInfos = walletLockBlock[wallet];
        for (uint256 i = 0; i < lockInfos.length; i++) {
            lockInfos[i].unlockAt = lockInfos[i].lockedAt + blockNumber;
        }

        emit UpdateLockBlock(wallet, blockNumber);
    }

    function transferAndLock(
        address to,
        uint256 value,
        uint256 lockSeconds
    ) external onlyOwnerOrLockTransferAdmin {
        uint256 lockedAt = block.timestamp;
        uint256 unLockAt = lockedAt + lockSeconds;
        LockInfo[] storage infos = walletLockBlock[to];
        infos.push(LockInfo(lockedAt, value, unLockAt));
        transfer(to, value);

        emit TransferAndLock(msg.sender, to, value, block.number);
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        if (to == address(0)) {
            return super.transfer(to, amount);
        }
        if (amount == 0) {
            return super.transfer(to, amount);
        }

        address from = msg.sender;
        if (isLockActive) {
            if (walletLockBlock[from].length > 0) {
                bool canTransfer = canTransferAmount(from, amount);
                require(canTransfer, "wallet is locked");
            }
        }
        return super.transfer(to, amount);
    }

    function canTransferAmount(
        address from,
        uint256 transferAmount
    ) internal view returns (bool) {
        LockInfo[] storage lockInfos = walletLockBlock[from];
        if (lockInfos.length == 0) {
            return true;
        }

        uint256 lockedAmount = 0;
        for (uint256 i = 0; i < lockInfos.length; i++) {
            if (block.timestamp < lockInfos[i].unlockAt) {
                lockedAmount += lockInfos[i].lockedAmount;
            }
        }

        uint256 availableAmount = IERC20(this).balanceOf(from) - lockedAmount;
        return (availableAmount >= transferAmount);
    }

    function getAvailableAmount(
        address caller
    ) public view returns (uint256, uint256) {
        LockInfo[] storage lockInfos = walletLockBlock[caller];

        uint256 lockedAmount = 0;
        for (uint256 i = 0; i < lockInfos.length; i++) {
            if (block.timestamp < lockInfos[i].unlockAt) {
                lockedAmount += lockInfos[i].lockedAmount;
            }
        }
        uint256 total = IERC20(this).balanceOf(caller);
        uint256 availableAmount = IERC20(this).balanceOf(caller) - lockedAmount;
        return (total, availableAmount);
    }

    function getLockAmountAndUnlockAt(
        address caller,
        uint16 index
    ) public view returns (uint256, uint256) {
        if (walletLockBlock[caller].length < index) {
            return (0, 0);
        }

        LockInfo memory lockInfo = walletLockBlock[caller][index];
        return (lockInfo.lockedAmount, lockInfo.unlockAt);
    }

    function addLockTransferAdmin(address wallet) external onlyOwner {
        lockTransferAdmins.push(wallet);
    }
}
