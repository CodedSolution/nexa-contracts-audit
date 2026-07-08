// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title WLP (Working Liquidity Pool)
 * @notice ERC20 token representing platform liquidity for refinancing
 * @dev Platform-owned contract, admin mints when financiers deposit fiat
 *      WLP is burned after supplier receives fiat
 *      WLP is minted to financier when buyer pays at settlement
 *      UPGRADEABLE via UUPS proxy pattern
 */
contract WLP is 
    Initializable,
    ERC20Upgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable 
{
    /// @notice Total fiat reserves backing WLP (tracked off-chain, logged on-chain)
    uint256 public fiatReserves;

    /// @notice Maximum supply cap (prevent runaway minting)
    uint256 public maxSupply;

    // Events
    event WLPMinted(address indexed to, uint256 amount, uint256 newReserves);
    event WLPBurned(address indexed from, uint256 amount, uint256 newReserves);
    event FiatDeposited(address indexed financier, uint256 amount);
    event FiatWithdrawn(address indexed financier, uint256 amount);
    event ReservesUpdated(uint256 oldReserves, uint256 newReserves);
    event MaxSupplyUpdated(uint256 oldMax, uint256 newMax);

    // Errors

    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientReserves();
    error UnauthorizedUpgrade();
    error InvalidAmount();
    error ReservesImbalanced();
    error ReservesTooHigh();
    error MaxSupplyExceeded();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize WLP token (replaces constructor)
     * @param _owner Address of platform administrator/owner
     */
    function initialize(address _owner) public initializer {
        if (_owner == address(0)) revert InvalidAddress();
        
        __ERC20_init("Working Liquidity Pool", "WLP");
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        // Set initial max supply to 1 billion WLP (18 decimals)
        maxSupply = 1_000_000_000 * 10**18;
        transferOwnership(_owner);
    }

    /**
     * @notice Mint WLP tokens (only platform admin)
     * @dev Called when financier deposits fiat or buyer pays at settlement
     * @param to Recipient address (financier)
     * @param amount Amount to mint (equals fiat deposited)
     */
    function mint(address to, uint256 amount) external onlyOwner whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (totalSupply() + amount > maxSupply) revert MaxSupplyExceeded();
        
        _mint(to, amount);
        fiatReserves += amount;
        
        // Verify reserves match total supply (invariant check)
        if (fiatReserves != totalSupply()) revert ReservesImbalanced();
        
        emit WLPMinted(to, amount, fiatReserves);
    }

    /**
     * @notice Burn WLP tokens (only platform admin)
     * @dev Called after supplier receives fiat for refinancing
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (balanceOf(from) < amount) revert InsufficientBalance();
        if (fiatReserves < amount) revert InsufficientReserves();
        
        _burn(from, amount);
        fiatReserves -= amount;
        
        // Verify reserves match total supply (invariant check)
        if (fiatReserves != totalSupply()) revert ReservesImbalanced();
        
        emit WLPBurned(from, amount, fiatReserves);
    }

    /**
     * @notice Record fiat deposit (off-chain event logged on-chain)
     * @param financier Address of financier
     * @param amount Amount deposited
     */
    function recordFiatDeposit(address financier, uint256 amount) external onlyOwner {
        if (financier == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        emit FiatDeposited(financier, amount);
    }

    /**
     * @notice Record fiat withdrawal (off-chain event logged on-chain)
     * @param financier Address of financier
     * @param amount Amount withdrawn
     */
    function recordFiatWithdrawal(address financier, uint256 amount) external onlyOwner {
        if (financier == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        emit FiatWithdrawn(financier, amount);
    }

    /**
     * @notice Update fiat reserves manually (admin correction)
     * @dev May temporarily break reserves==supply invariant until next mint/burn
     * @dev Intended for off-chain accounting corrections (e.g., bank reconciliation)
     * @dev Monitor isBalanced() view function for operational health checks
     * @dev Sanity check: reserves shouldn't exceed 2x total supply to prevent mistakes
     * @param newReserves New reserve amount
     */
    function updateReserves(uint256 newReserves) external onlyOwner {
        // Sanity check: reserves shouldn't be more than 2x total supply
        if (newReserves > totalSupply() * 2) revert ReservesTooHigh();
        
        uint256 oldReserves = fiatReserves;
        fiatReserves = newReserves;
        
        emit ReservesUpdated(oldReserves, newReserves);
    }

    /**
     * @notice Update maximum supply cap (admin only)
     * @param newMaxSupply New maximum supply
     */
    function updateMaxSupply(uint256 newMaxSupply) external onlyOwner {
        if (newMaxSupply < totalSupply()) revert InvalidAmount(); // Can't set below current supply
        
        uint256 oldMax = maxSupply;
        maxSupply = newMaxSupply;
        
        emit MaxSupplyUpdated(oldMax, newMaxSupply);
    }

    /**
     * @notice Get total fiat reserves
     * @return Current fiat reserves amount
     */
    function getTotalReserves() external view returns (uint256) {
        return fiatReserves;
    }

    /**
     * @notice Check if reserves match total supply (should always be true)
     * @return True if balanced
     */
    function isBalanced() external view returns (bool) {
        return fiatReserves == totalSupply();
    }

    /**
     * @notice Pause token transfers (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Override _beforeTokenTransfer to add pause functionality
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @notice Authorize upgrade (only owner can upgrade)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert InvalidAddress();
    }

    /**
     * @notice Get current implementation version
     * @return Version string
     */
    function version() public pure virtual returns (string memory) {
        return "1.1.0";
    }
}
