// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title WTKN (Wrapped Token)
 * @notice ERC20 collateral token deployed per anchor buyer
 * @dev Each anchor buyer deploys their own WTKN contract
 *      WTKN is staked into ROR contract when invoice is created
 *      Released back to buyer when invoice settles or expires
 *      UPGRADEABLE via UUPS proxy pattern
 */
contract WTKN is 
    Initializable,
    ERC20Upgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable 
{
    /// @notice Address of the anchor buyer who owns this WTKN contract
    address public anchorBuyer;

    /// @notice Mapping of authorized ROR contracts (supports multiple RORs per WTKN)
    mapping(address => bool) public authorizedRORContracts;
    
    /// @notice List of all authorized ROR contracts for enumeration
    address[] public rorContractList;
    
    /// @notice Legacy: First registered ROR contract (for backwards compatibility)
    address public rorContract;

    /// @notice Total amount of WTKN currently staked in ROR contracts
    uint256 public totalStaked;

    /// @notice Track staked amount per ROR token ID
    mapping(uint256 => uint256) public stakedPerToken;

    /// @notice Minimum mint amount (prevent dust tokens)
    uint256 public constant MIN_MINT_AMOUNT = 1000; // 0.000000000000001 WTKN (18 decimals)

    /// @notice Blacklist for regulatory compliance
    mapping(address => bool) public blacklisted;

    /// @notice Staked amount per (ROR contract, ROR token id).
    /// @dev ROR token ids are NOT globally unique — every ROR contract restarts
    /// its counter at MIN_TOKEN_ID (1000) — and one WTKN is shared across many
    /// ROR contracts. Keying stakes by token id alone made the 2nd+ ROR contract
    /// collide on the same id. Staking is therefore keyed by the calling ROR
    /// contract. `stakedPerToken` above is retained (never reordered) to preserve
    /// UUPS storage layout and to service legacy stakes recorded before this fix.
    mapping(address => mapping(uint256 => uint256)) public stakedPerRorToken;

    // Events
    event RORContractSet(address indexed rorContract); // Legacy event
    event RORContractAdded(address indexed rorContract);
    event RORContractRemoved(address indexed rorContract);
    event WTKNMinted(address indexed to, uint256 amount);
    event WTKNBurned(address indexed from, uint256 amount);
    event WTKNStaked(uint256 indexed rorTokenId, uint256 amount);
    event WTKNUnstaked(uint256 indexed rorTokenId, uint256 amount);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    // Errors
    error OnlyAnchorBuyer();
    error OnlyRORContract();
    error RORContractAlreadySet(); // Legacy error
    error RORAlreadyAuthorized();
    error RORNotAuthorized();
    error InvalidAddress();
    error InsufficientBalance();
    error UnauthorizedUpgrade();
    error UnauthorizedTransfer();
    error InvalidAmount();
    error InvalidUnstakeAmount();
    error AddressBlacklisted();
    error EmptyString();
    error RORContractNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize WTKN token (replaces constructor)
     * @param _name Token name (e.g., "BuyerA Collateral")
     * @param _symbol Token symbol (e.g., "WTKN-A")
     * @param _anchorBuyer Address of the anchor buyer who owns this WTKN
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _anchorBuyer
    ) public initializer {
        if (_anchorBuyer == address(0)) revert InvalidAddress();
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyString();
        
        __ERC20_init(_name, _symbol);
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        anchorBuyer = _anchorBuyer;
        transferOwnership(_anchorBuyer);
    }

    /**
     * @notice Add authorized ROR contract (supports multiple RORs)
     * @param _rorContract Address of the ROR_ERC1155 contract to authorize
     */
    function addRORContract(address _rorContract) external onlyOwner {
        if (_rorContract == address(0)) revert InvalidAddress();
        if (authorizedRORContracts[_rorContract]) revert RORAlreadyAuthorized();
        
        authorizedRORContracts[_rorContract] = true;
        rorContractList.push(_rorContract);
        
        // Set as legacy rorContract if first one
        if (rorContract == address(0)) {
            rorContract = _rorContract;
        }
        
        emit RORContractAdded(_rorContract);
        emit RORContractSet(_rorContract); // Legacy event for backwards compatibility
    }
    
    /**
     * @notice Remove authorized ROR contract
     * @param _rorContract Address of the ROR contract to remove
     */
    function removeRORContract(address _rorContract) external onlyOwner {
        if (!authorizedRORContracts[_rorContract]) revert RORNotAuthorized();
        
        authorizedRORContracts[_rorContract] = false;
        emit RORContractRemoved(_rorContract);
    }
    
    /**
     * @notice LEGACY: Set ROR contract address (backwards compatible)
     * @dev This function now adds the ROR to authorized list instead of replacing
     * @param _rorContract Address of the ROR_ERC1155 contract
     */
    function setRORContract(address _rorContract) external onlyOwner {
        if (_rorContract == address(0)) revert InvalidAddress();
        if (authorizedRORContracts[_rorContract]) revert RORAlreadyAuthorized();
        
        authorizedRORContracts[_rorContract] = true;
        rorContractList.push(_rorContract);
        
        // Set as legacy rorContract if first one
        if (rorContract == address(0)) {
            rorContract = _rorContract;
        }
        
        emit RORContractAdded(_rorContract);
        emit RORContractSet(_rorContract);
    }
    
    /**
     * @notice Check if ROR contract is authorized
     * @param _rorContract Address to check
     * @return bool True if authorized
     */
    function isRORAuthorized(address _rorContract) external view returns (bool) {
        return authorizedRORContracts[_rorContract];
    }
    
    /**
     * @notice Get count of authorized ROR contracts
     * @return uint256 Number of authorized RORs
     */
    function getAuthorizedRORCount() external view returns (uint256) {
        return rorContractList.length;
    }

    /**
     * @notice Mint WTKN tokens (only anchor buyer)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (amount < MIN_MINT_AMOUNT) revert InvalidAmount();
        
        _mint(to, amount);
        emit WTKNMinted(to, amount);
    }

    /**
     * @notice Burn WTKN tokens (only anchor buyer)
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        
        _burn(msg.sender, amount);
        emit WTKNBurned(msg.sender, amount);
    }

    /**
     * @notice Record staking event (called by ROR contract)
     * @param rorTokenId ROR token ID
     * @param amount Amount staked
     */
    function recordStake(uint256 rorTokenId, uint256 amount) external {
        if (!authorizedRORContracts[msg.sender]) revert OnlyRORContract();
        if (amount == 0) revert InvalidAmount();
        // Key by (ROR contract, token id). Token ids collide across ROR contracts
        // sharing this WTKN, so a token-id-only guard wrongly blocked every mint
        // after the first for a given buyer.
        if (stakedPerRorToken[msg.sender][rorTokenId] > 0) revert InvalidAmount(); // Prevent double staking

        totalStaked += amount;
        stakedPerRorToken[msg.sender][rorTokenId] = amount;
        emit WTKNStaked(rorTokenId, amount);
    }

    /**
     * @notice Record unstaking event (called by ROR contract)
     * @param rorTokenId ROR token ID
     * @param amount Amount unstaked
     */
    function recordUnstake(uint256 rorTokenId, uint256 amount) external {
        if (!authorizedRORContracts[msg.sender]) revert OnlyRORContract();
        if (amount == 0) revert InvalidAmount();
        if (amount > totalStaked) revert InvalidUnstakeAmount();

        uint256 perRor = stakedPerRorToken[msg.sender][rorTokenId];
        if (perRor >= amount) {
            stakedPerRorToken[msg.sender][rorTokenId] = perRor - amount;
        } else if (stakedPerToken[rorTokenId] >= amount) {
            // Legacy stake recorded before per-ROR keying — unstake from old map.
            stakedPerToken[rorTokenId] -= amount;
        } else {
            revert InvalidUnstakeAmount();
        }

        totalStaked -= amount;
        emit WTKNUnstaked(rorTokenId, amount);
    }

    /**
     * @notice Get available (unstaked) balance
     * @param account Address to check
     * @return Available balance
     */
    function availableBalance(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @notice Get staked amount for specific ROR token
     * @param rorTokenId ROR token ID
     * @return Staked amount
     */
    function getStakedAmount(uint256 rorTokenId) external view returns (uint256) {
        return stakedPerToken[rorTokenId]; // legacy global view (pre-fix stakes)
    }

    /// @notice Staked amount for a specific ROR contract's token (post-fix keying).
    function getStakedAmountForRor(address ror, uint256 rorTokenId) external view returns (uint256) {
        return stakedPerRorToken[ror][rorTokenId];
    }

    /**
     * @notice Blacklist an address (compliance)
     * @param account Address to blacklist
     */
    function addToBlacklist(address account) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Remove address from blacklist
     * @param account Address to unblacklist
     */
    function removeFromBlacklist(address account) external onlyOwner {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    /**
     * @notice Pause token transfers (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Override transfer to restrict destinations
     * @dev WTKN can only be transferred to anchorBuyer (return collateral) or authorized ROR contracts (staking)
     * @dev After releaseWTKN, any holder can return WTKN to anchorBuyer
     * @dev Exception: Authorized ROR contracts can transfer to anyone (for proportional release to holders)
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Check blacklist for sender and recipient (consistent with transferFrom)
        if (blacklisted[msg.sender]) revert AddressBlacklisted();
        if (blacklisted[to]) revert AddressBlacklisted();
        
        // Allow any authorized ROR contract to transfer to anyone (for releasing WTKN to holders)
        if (authorizedRORContracts[msg.sender]) {
            return super.transfer(to, amount);
        }
        
        // Restrict others: allow transfer to anchorBuyer (return collateral) or any authorized ROR contract (staking)
        if (to != anchorBuyer && !authorizedRORContracts[to]) {
            revert UnauthorizedTransfer();
        }
        return super.transfer(to, amount);
    }

    /**
     * @notice Override transferFrom to restrict destinations
     * @dev WTKN can only be transferred to anchorBuyer (return collateral) or authorized ROR contracts (staking)
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Check blacklist
        if (blacklisted[from]) revert AddressBlacklisted();
        if (blacklisted[to]) revert AddressBlacklisted();
        
        if (to != anchorBuyer && !authorizedRORContracts[to]) {
            revert UnauthorizedTransfer();
        }
        return super.transferFrom(from, to, amount);
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
        return "2.0.0";
    }
}
