// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Points is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public deployedAt;
    event Mint(address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __ERC20_init("DeepLink Points", "DLP");
        __ERC20Permit_init("DeepLink Points");
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);

   
        uint256 initSupply = 100_000_000 * 10 ** decimals();
        _mint(initialOwner, initSupply);
        deployedAt = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        require(newImplementation != address(0), "Invalid implementation address");
    }

    function mint(uint256 amount) external onlyOwner {
        require(msg.sender == owner(), "not owner");

        _mint(msg.sender, amount);
        emit Mint(msg.sender, amount);
    }
}
