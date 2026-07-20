// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title SubPool
 * @notice Investor liquidity pool for a single Anchor Buyer.
 *         Investors allocate WLP tokens and receive Units (internal accounting token).
 *         Pool capital finances suppliers via ROR invoices; yield accrues via NAV appreciation.
 * @dev UPGRADEABLE via UUPS proxy pattern. One contract per Anchor Buyer.
 *      Units are pre-minted at deployment and transferred on allocate (not minted).
 *      NAV is pushed daily by the backend (oracle pattern).
 */
contract SubPool is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC1155HolderUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════
    //                          STRUCTS
    // ═══════════════════════════════════════════════════════════════

    struct Allocation {
        uint256 wlpAmount;       // WLP deposited by investor
        uint256 unitsIssued;     // Units transferred to investor
        uint256 allocatedAt;     // Block timestamp of allocation
        uint256 lockUpEndsAt;    // allocatedAt + lockUpSeconds (per-allocation)
        bool redeemed;           // Whether this allocation has been redeemed
        uint8 investmentType;    // 0 = Participatory, 1 = Series
        uint256 seriesId;        // Series ID (0 for Participatory)
    }

    struct Series {
        string name;             // Human-readable label e.g. "Series A"
        uint256 lockUpSeconds;   // Lock-up duration for this series
        uint256 startDate;       // Allocation window opens (unix timestamp)
        uint256 endDate;         // Allocation window closes (unix timestamp)
        uint256 maxSize;         // Maximum WLP this series can accept (0 = unlimited)
        uint256 minAllocation;   // Minimum WLP per investor (0 = no minimum)
        uint256 totalAllocated;  // Running total WLP allocated into this series
        bool active;             // Admin can deactivate to stop new allocations
    }

    struct FinancingRecord {
        // Original fields — order preserved for storage compatibility.
        address rorContract;     // ROR ERC1155 contract address
        uint256 rorTokenId;      // Token ID within the ROR contract
        uint256 wlpDeployed;     // Discounted amount sent to supplier
        uint256 faceValue;       // Full expected return at maturity
        uint256 financedAt;      // Block timestamp
        bool settled;            // Whether settlement has been received
        bool defaulted;          // Whether this financing has defaulted
        // Appended fields — added at the END so existing records read cleanly.
        uint256 financingId;     // Pool-assigned id (unique per financing on a token)
        uint256 platformFeeOwed; // Platform fee earmarked at financing (not unit-backing)
        uint256 reserveFeeOwed;  // Reserve fund fee earmarked at financing (not unit-backing)
        bool platformFeeCollected; // Whether the platform fee has been swept out
        bool reserveFeeCollected;  // Whether the reserve fund fee has been swept out
    }

    // ═══════════════════════════════════════════════════════════════
    //                       STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════

    // ─── Pool Configuration ───
    string public poolName;
    IERC20 public wlpToken;
    address public feeWallet;
    uint256 public lockUpDuration;
    uint256 public maxUtilisationBps;
    uint256 public earlyExitPenaltyBps;
    uint256 public minimumAllocation;

    // ─── NAV State ───
    uint256 public currentNav;       // NAV per unit (18 decimals, starts at 1e18)
    uint256 public navTimestamp;     // When NAV was last updated

    // ─── Pool Accounting ───
    uint256 public totalWlpBalance;              // WLP held by contract (available capital, excludes earmarked fees)
    uint256 public totalFinancedOutstanding;     // WLP deployed to financings (not yet settled)
    uint256 public totalPlatformFeesCollected;

    // ─── Unit Token (internal accounting) ───
    string public unitName;
    string public unitSymbol;
    uint8 public constant UNIT_DECIMALS = 18;
    uint256 public maxPoolSize;                  // Maximum WLP amount the pool can accept (RM cap)
    uint256 public totalUnitsInCirculation;      // Units currently in existence (held by investors)
    mapping(address => uint256) public unitBalanceOf;

    // ─── Allocations ───
    mapping(address => Allocation[]) internal _allocations;

    // ─── Financing Records ───
    mapping(bytes32 => FinancingRecord) public financings;

    // ─── WTKN Token (received from ROR settlement) ───
    IERC20 public wtknToken;

    // ─── Series Registry ───
    mapping(uint256 => Series) public seriesRegistry;
    uint256 public seriesCount;

    // ─── Investor Allowlist ───
    // Appended after all prior state to preserve UUPS proxy storage layout.
    // whitelistEnabled defaults to false on upgrade, so existing pools keep
    // their open-allocation behaviour until the owner explicitly turns it on.
    mapping(address => bool) public isWhitelisted;
    bool public whitelistEnabled;

    // ─── Fee / Reserve & per-financing accounting ───
    // Appended after all prior state (and consuming from __gap) to preserve the
    // UUPS proxy storage layout on upgrade. Do NOT reorder or insert above this.
    address public reserveFundWallet;            // Destination for reserve fund fees
    uint256 public totalReserveFundCollected;    // Cumulative reserve fund fees swept out
    // Active (unsettled, non-defaulted) financingIds per token key — enables
    // settling/defaulting all of a token's financings at once without a param.
    mapping(bytes32 => uint256[]) internal tokenActiveFinancings;
    // Monotonic financingId counter per token key. The pool assigns the id so a
    // token can be financed repeatedly without collisions or an external source.
    mapping(bytes32 => uint256) public nextFinancingId;

    // ─── Storage Gap ───
    // Reduced from 50 → 46 to account for the 4 slots consumed above, keeping
    // the total reserved storage footprint constant across this upgrade.
    uint256[46] private __gap;

    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════

    event NavUpdated(uint256 newNav, uint256 timestamp);
    event NavChangeAlert(uint256 previousNav, uint256 newNav, uint256 changeBps);
    event Allocated(
        address indexed investor,
        uint256 wlpAmount,
        uint256 unitsIssued,
        uint256 allocationIndex,
        uint256 lockUpEndsAt,
        uint8 investmentType
    );
    event Redeemed(
        address indexed investor,
        uint256 unitsReturned,
        uint256 wlpReturned,
        uint256 allocationIndex,
        bool early
    );
    event SupplierFinanced(
        address indexed supplier,
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 financingId,
        uint256 wlpAmount,
        uint256 faceValue
    );
    event SettlementReceived(
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 wlpAmount
    );
    event DefaultRecorded(
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 lossAmount
    );
    event PlatformFeeCollected(address indexed rorContract, uint256 indexed tokenId, uint256 indexed financingId, uint256 amount, address feeWallet);
    event ReserveFundCollected(address indexed rorContract, uint256 indexed tokenId, uint256 indexed financingId, uint256 amount, address reserveFundWallet);
    event ReserveFundWalletUpdated(address oldWallet, address newWallet);
    event InterestReceived(uint256 wlpAmount);
    event MaxPoolSizeUpdated(uint256 oldSize, uint256 newSize);
    event LockUpDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MaxUtilisationUpdated(uint256 oldBps, uint256 newBps);
    event EarlyExitPenaltyUpdated(uint256 oldBps, uint256 newBps);
    event FeeWalletUpdated(address oldWallet, address newWallet);
    event MinimumAllocationUpdated(uint256 oldAmount, uint256 newAmount);
    event WTKNReturnedToBuyer(address indexed buyer, uint256 amount);
    event RORBurned(address indexed rorContract, uint256 indexed tokenId, uint256 amount);
    event SeriesCreated(uint256 indexed seriesId, string name, uint256 lockUpSeconds, uint256 startDate, uint256 endDate, uint256 maxSize);
    event SeriesUpdated(uint256 indexed seriesId, uint256 startDate, uint256 endDate, uint256 maxSize, uint256 minAllocation);
    event SeriesDeactivated(uint256 indexed seriesId);
    event WhitelistUpdated(address indexed investor, bool status);
    event WhitelistToggled(bool enabled);
    // Recovery / migration
    event FinancingReindexed(address indexed rorContract, uint256 indexed tokenId, uint256 financingId, uint256 faceValue);
    event OutstandingReconciled(uint256 oldValue, uint256 newValue);
    event Migrated(uint64 version);

    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error InvalidBps();
    error NavNotSet();
    error LockUpNotExpired(uint256 lockUpEndsAt);
    error AllocationAlreadyRedeemed();
    error AllocationIndexOutOfBounds();
    error InsufficientLiquidity(uint256 available, uint256 required);
    error PoolSizeExceeded(uint256 newSize, uint256 maxSize);
    error UtilisationExceeded(uint256 currentUtilisation, uint256 maxUtilisation);
    error FinancingAlreadyExists(bytes32 key);
    error FinancingNotFound(bytes32 key);
    error FinancingAlreadySettled(bytes32 key);
    error FinancingAlreadyDefaulted(bytes32 key);
    error FeesAlreadyCollected(bytes32 key);
    error BelowMinimumAllocation(uint256 amount, uint256 minimum);
    error SeriesNotFound(uint256 seriesId);
    error SeriesNotActive(uint256 seriesId);
    error SeriesNotStarted(uint256 seriesId, uint256 startDate);
    error SeriesEnded(uint256 seriesId, uint256 endDate);
    error SeriesMaxSizeExceeded(uint256 seriesId, uint256 available, uint256 requested);
    error InvalidSeriesConfig();
    error NotWhitelisted(address investor);

    // ═══════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═══════════════════════════════════════════════════════════════
    //                        INITIALIZER
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the Sub-Pool (replaces constructor for proxy)
     * @param _poolName Human-readable pool name (e.g. "Buyer ABC Sub-Pool")
     * @param _unitName Unit token name (e.g. "Buyer ABC Units")
     * @param _unitSymbol Unit token symbol (e.g. "UABC")
     * @param _wlpToken WLP ERC20 token address
     * @param _feeWallet Platform/trustee wallet for fee collection
     * @param _owner Pool wallet (EOA) that will own this contract
     * @param _maxPoolSize Maximum WLP amount the pool can accept (e.g. 5000000e18 for RM5M)
     * @param _lockUpDuration Lock-up duration in seconds (e.g. 15552000 for 180 days)
     * @param _maxUtilisationBps Max utilisation in basis points (e.g. 9000 = 90%)
     * @param _earlyExitPenaltyBps Early exit penalty in basis points (e.g. 500 = 5%)
     * @param _minimumAllocation Minimum WLP amount per allocation
     */
    function initialize(
        string memory _poolName,
        string memory _unitName,
        string memory _unitSymbol,
        address _wlpToken,
        address _feeWallet,
        address _reserveFundWallet,
        address _owner,
        uint256 _maxPoolSize,
        uint256 _lockUpDuration,
        uint256 _maxUtilisationBps,
        uint256 _earlyExitPenaltyBps,
        uint256 _minimumAllocation
    ) public initializer {
        if (_wlpToken == address(0)) revert InvalidAddress();
        if (_feeWallet == address(0)) revert InvalidAddress();
        if (_reserveFundWallet == address(0)) revert InvalidAddress();
        if (_reserveFundWallet == _feeWallet) revert InvalidAddress();
        if (_owner == address(0)) revert InvalidAddress();
        if (_maxPoolSize == 0) revert InvalidAmount();
        if (_maxUtilisationBps == 0 || _maxUtilisationBps > 10000) revert InvalidBps();
        if (_earlyExitPenaltyBps > 5000) revert InvalidBps(); // Max 50% penalty

        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        poolName = _poolName;
        unitName = _unitName;
        unitSymbol = _unitSymbol;
        wlpToken = IERC20(_wlpToken);
        feeWallet = _feeWallet;
        reserveFundWallet = _reserveFundWallet;
        lockUpDuration = _lockUpDuration;
        maxUtilisationBps = _maxUtilisationBps;
        earlyExitPenaltyBps = _earlyExitPenaltyBps;
        minimumAllocation = _minimumAllocation;

        // Set max pool size cap (total WLP amount the pool can accept)
        maxPoolSize = _maxPoolSize;

        // NAV starts at 1.0 (1e18)
        currentNav = 1e18;
        navTimestamp = block.timestamp;

        transferOwnership(_owner);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Restricts allocation to whitelisted investors when the allowlist
     *      is enabled. When whitelistEnabled is false the check is a no-op,
     *      preserving open allocation for pools that have not opted in.
     */
    modifier onlyWhitelisted() {
        if (whitelistEnabled && !isWhitelisted[msg.sender]) revert NotWhitelisted(msg.sender);
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                     INVESTOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Allocate WLP into the pool and receive Units at current NAV price
     * @dev Investor must have approved this contract to spend their WLP
     * @param wlpAmount Amount of WLP to allocate
     * @param investmentType 0 = Participatory, 1 = Series
     * @param seriesId Series ID to allocate into (ignored for Participatory — pass 0)
     */
    function allocate(uint256 wlpAmount, uint8 investmentType, uint256 seriesId) external onlyWhitelisted whenNotPaused nonReentrant {
        if (wlpAmount == 0) revert InvalidAmount();
        if (currentNav == 0) revert NavNotSet();
        if (investmentType > 1) revert InvalidAmount();

        uint256 lockUpSeconds;

        if (investmentType == 0) {
            // Participatory — use pool-level lock-up and minimum
            if (wlpAmount < minimumAllocation) revert BelowMinimumAllocation(wlpAmount, minimumAllocation);
            lockUpSeconds = lockUpDuration;
            seriesId = 0;
        } else {
            // Series — validate series registry and enforce its rules
            Series storage s = seriesRegistry[seriesId];
            if (!s.active) revert SeriesNotActive(seriesId);
            if (s.lockUpSeconds == 0) revert SeriesNotFound(seriesId);
            if (block.timestamp < s.startDate) revert SeriesNotStarted(seriesId, s.startDate);
            if (s.endDate > 0 && block.timestamp > s.endDate) revert SeriesEnded(seriesId, s.endDate);
            if (s.minAllocation > 0 && wlpAmount < s.minAllocation) revert BelowMinimumAllocation(wlpAmount, s.minAllocation);
            if (s.maxSize > 0) {
                // Write before check: revert unwinds the write atomically.
                // Two txs in the same block both pass the old read-then-check
                // pattern; with update-then-revert only one survives.
                s.totalAllocated += wlpAmount;
                if (s.totalAllocated > s.maxSize) {
                    // available = maxSize - totalAllocated_before = maxSize + wlpAmount - totalAllocated_after
                    revert SeriesMaxSizeExceeded(seriesId, s.maxSize + wlpAmount - s.totalAllocated, wlpAmount);
                }
            } else {
                s.totalAllocated += wlpAmount;
            }
            lockUpSeconds = s.lockUpSeconds;
        }

        // Calculate units to issue: units = wlpAmount * 1e18 / currentNav
        uint256 unitsToIssue = (wlpAmount * 1e18) / currentNav;
        if (unitsToIssue == 0) revert InvalidAmount();

        // Check pool size cap (total WLP in pool must not exceed maxPoolSize)
        uint256 newPoolSize = totalWlpBalance + totalFinancedOutstanding + wlpAmount;
        if (newPoolSize > maxPoolSize) revert PoolSizeExceeded(newPoolSize, maxPoolSize);

        // Transfer WLP from investor to contract
        wlpToken.safeTransferFrom(msg.sender, address(this), wlpAmount);

        // Mint units to investor
        unitBalanceOf[msg.sender] += unitsToIssue;
        totalUnitsInCirculation += unitsToIssue;

        // Update pool accounting
        totalWlpBalance += wlpAmount;

        // Record allocation
        uint256 lockUpEndsAt = block.timestamp + lockUpSeconds;
        _allocations[msg.sender].push(Allocation({
            wlpAmount: wlpAmount,
            unitsIssued: unitsToIssue,
            allocatedAt: block.timestamp,
            lockUpEndsAt: lockUpEndsAt,
            redeemed: false,
            investmentType: investmentType,
            seriesId: seriesId
        }));

        uint256 allocationIndex = _allocations[msg.sender].length - 1;

        emit Allocated(msg.sender, wlpAmount, unitsToIssue, allocationIndex, lockUpEndsAt, investmentType);
    }

    /**
     * @notice Redeem an allocation after lock-up period has expired
     * @param allocationIndex Index of the allocation to redeem
     */
    function redeem(uint256 allocationIndex) external whenNotPaused nonReentrant {
        _redeem(msg.sender, allocationIndex, false);
    }

    /**
     * @notice Redeem an allocation before lock-up expires (with penalty)
     * @param allocationIndex Index of the allocation to redeem early
     */
    function redeemEarly(uint256 allocationIndex) external whenNotPaused nonReentrant {
        _redeem(msg.sender, allocationIndex, true);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Update NAV per unit (daily oracle push by backend)
     * @param newNav New NAV per unit (18 decimals)
     */
    function updateNav(uint256 newNav) external onlyOwner {
        if (newNav == 0) revert InvalidAmount();
        // Floor: 0.001e18 — prevents unit overflow on allocation.
        // Ceiling: 1000e18 — prevents redemptions returning near-zero WLP.
        if (newNav < 1e15 || newNav > 1000e18) revert InvalidAmount();

        uint256 prev = currentNav;
        currentNav = newNav;
        navTimestamp = block.timestamp;

        // Emit alert for swings > 20% so monitoring can flag mis-keys.
        if (prev > 0) {
            uint256 changeBps = newNav > prev
                ? ((newNav - prev) * 10000) / prev
                : ((prev - newNav) * 10000) / prev;
            if (changeBps > 2000) emit NavChangeAlert(prev, newNav, changeBps);
        }

        emit NavUpdated(newNav, block.timestamp);
    }

    /**
     * @notice Finance a supplier — transfer discounted WLP from pool to supplier
     * @param supplier Supplier wallet address to receive WLP
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID
     * @param wlpAmount Discounted WLP amount to send to supplier
     * @param faceValue Full face value expected at maturity
     * @param platformFee Platform fee earmarked from the discount (swept via collectPlatformFee)
     * @param reserveFee Reserve fund fee earmarked from the discount (swept via collectReserveFund)
     * @return financingId Pool-assigned id, unique per token; carried in SupplierFinanced
     */
    function financeSupplier(
        address supplier,
        address rorContract,
        uint256 tokenId,
        uint256 wlpAmount,
        uint256 faceValue,
        uint256 platformFee,
        uint256 reserveFee
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256 financingId) {
        if (supplier == address(0)) revert InvalidAddress();
        if (rorContract == address(0)) revert InvalidAddress();
        if (wlpAmount == 0 || faceValue == 0) revert InvalidAmount();
        if (faceValue < wlpAmount) revert InvalidAmount();

        // The pool assigns its own financingId per token (like ROR nextFinancingId),
        // so a token can be financed repeatedly with no key collision and no
        // dependency on any externally-sourced id.
        bytes32 tKey = _tokenKey(rorContract, tokenId);
        financingId = ++nextFinancingId[tKey];
        bytes32 key = _financingKey(rorContract, tokenId, financingId);

        // Check utilisation cap
        uint256 poolValue = totalWlpBalance + totalFinancedOutstanding;
        uint256 newOutstanding = totalFinancedOutstanding + faceValue;
        if (poolValue > 0) {
            uint256 utilisationAfter = (newOutstanding * 10000) / poolValue;
            if (utilisationAfter > maxUtilisationBps) {
                revert UtilisationExceeded(utilisationAfter, maxUtilisationBps);
            }
        }

        // The discount retained in the pool must cover both the fees we earmark
        // and still leave the amount sent to the supplier backed by real capital.
        uint256 totalCommit = wlpAmount + platformFee + reserveFee;

        // Verify tracked balance matches actual contract balance to detect drift.
        // Use the lesser of the two as the available liquidity so we never
        // over-commit capital that the contract doesn't actually hold.
        uint256 actualBalance = wlpToken.balanceOf(address(this));
        uint256 available = totalWlpBalance < actualBalance ? totalWlpBalance : actualBalance;
        if (available < totalCommit) revert InsufficientLiquidity(available, totalCommit);

        // CEI: update all state before the external transfer call.
        // Fees are moved OUT of unit-backing capital and held as per-financing
        // liabilities, so they can never be counted as NAV backing or drained
        // as investor principal by fee collection.
        totalWlpBalance -= totalCommit;
        totalFinancedOutstanding += faceValue;
        financings[key] = FinancingRecord({
            rorContract: rorContract,
            rorTokenId: tokenId,
            financingId: financingId,
            wlpDeployed: wlpAmount,
            faceValue: faceValue,
            financedAt: block.timestamp,
            platformFeeOwed: platformFee,
            reserveFeeOwed: reserveFee,
            settled: false,
            defaulted: false,
            platformFeeCollected: false,
            reserveFeeCollected: false
        });
        tokenActiveFinancings[tKey].push(financingId);

        emit SupplierFinanced(supplier, rorContract, tokenId, financingId, wlpAmount, faceValue);

        // External call last (Checks-Effects-Interactions).
        // safeTransfer reverts on failure, rolling back all state changes above.
        wlpToken.safeTransfer(supplier, wlpAmount);
    }

    /**
     * @notice Record settlement received from buyer
     * @dev Buyer must have already transferred WLP to this contract before calling
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID
     * @param wlpAmount WLP amount received from buyer
     */
    function receiveSettlement(
        address rorContract,
        uint256 tokenId,
        uint256 wlpAmount
    ) external onlyOwner whenNotPaused {
        if (wlpAmount == 0) revert InvalidAmount();

        // The buyer settles the whole token at once. Settle every currently
        // active financing on it in one call — no per-financing id required.
        bytes32 tKey = _tokenKey(rorContract, tokenId);
        uint256[] storage ids = tokenActiveFinancings[tKey];
        if (ids.length == 0) revert FinancingNotFound(tKey);

        uint256 totalFace;
        for (uint256 i = 0; i < ids.length; i++) {
            FinancingRecord storage f = financings[_financingKey(rorContract, tokenId, ids[i])];
            f.settled = true;
            totalFace += f.faceValue;
        }
        delete tokenActiveFinancings[tKey];

        // Update accounting: reduce outstanding by the summed face value,
        // increase balance by the received amount (amount is trusted, as before).
        totalFinancedOutstanding -= totalFace;
        totalWlpBalance += wlpAmount;

        emit SettlementReceived(rorContract, tokenId, wlpAmount);
    }

    /**
     * @notice Receive interest income (STI) into the pool without issuing new units
     * @dev Used by the NAV engine to inject realized overnight interest (minted WLP)
     *      into the pool, increasing NAV per unit for all existing holders.
     * @param wlpAmount WLP amount of interest income to add to pool balance
     */
    function receiveInterest(uint256 wlpAmount) external onlyOwner whenNotPaused {
        if (wlpAmount == 0) revert InvalidAmount();

        totalWlpBalance += wlpAmount;

        emit InterestReceived(wlpAmount);
    }

    /**
     * @notice Record a default on a financing (bad debt write-off)
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID
     * @param lossAmount Amount of loss to write off
     */
    function recordDefault(
        address rorContract,
        uint256 tokenId,
        uint256 lossAmount
    ) external onlyOwner {
        if (lossAmount == 0) revert InvalidAmount();

        // Default writes off the whole token at once — mark every active
        // financing on it as defaulted so a later settlement can't re-process them.
        bytes32 tKey = _tokenKey(rorContract, tokenId);
        uint256[] storage ids = tokenActiveFinancings[tKey];
        if (ids.length == 0) revert FinancingNotFound(tKey);

        uint256 totalFace;
        for (uint256 i = 0; i < ids.length; i++) {
            FinancingRecord storage f = financings[_financingKey(rorContract, tokenId, ids[i])];
            f.defaulted = true;
            totalFace += f.faceValue;
        }
        delete tokenActiveFinancings[tKey];

        // Reduce outstanding by the summed face value of the defaulted financings
        // (mirrors receiveSettlement) so totalFinancedOutstanding stays an exact
        // gross face-value accumulator: no residual stranding when the recovered
        // loss differs from face value, no consumption of other tokens'
        // outstanding, and no later settlement underflow. lossAmount is reported
        // in the event as the economic loss but does not drive accounting — the
        // loss flows through NAV on the next update.
        totalFinancedOutstanding -= totalFace;

        emit DefaultRecorded(rorContract, tokenId, lossAmount);
    }

    /**
     * @notice Collect the platform fee accrued by a specific financing.
     * @dev The amount is fixed on-chain at financing time (platformFeeOwed) and
     *      was already excluded from unit-backing capital, so this can never
     *      touch investor principal. Idempotent per financing.
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID
     * @param financingId ROR financingId identifying the financing
     */
    function collectPlatformFee(
        address rorContract,
        uint256 tokenId,
        uint256 financingId
    ) external onlyOwner whenNotPaused {
        bytes32 key = _financingKey(rorContract, tokenId, financingId);
        FinancingRecord storage f = financings[key];
        if (f.financedAt == 0) revert FinancingNotFound(key);
        if (f.platformFeeCollected) revert FeesAlreadyCollected(key);

        uint256 amount = f.platformFeeOwed;
        f.platformFeeCollected = true;
        totalPlatformFeesCollected += amount;

        if (amount > 0) {
            wlpToken.safeTransfer(feeWallet, amount);
        }

        emit PlatformFeeCollected(rorContract, tokenId, financingId, amount, feeWallet);
    }

    /**
     * @notice Collect the reserve fund fee accrued by a specific financing.
     * @dev Mirror of collectPlatformFee, routed to reserveFundWallet. Replaces
     *      the old fee-wallet-swap workaround. Idempotent per financing.
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID
     * @param financingId ROR financingId identifying the financing
     */
    function collectReserveFund(
        address rorContract,
        uint256 tokenId,
        uint256 financingId
    ) external onlyOwner whenNotPaused {
        bytes32 key = _financingKey(rorContract, tokenId, financingId);
        FinancingRecord storage f = financings[key];
        if (f.financedAt == 0) revert FinancingNotFound(key);
        if (f.reserveFeeCollected) revert FeesAlreadyCollected(key);

        uint256 amount = f.reserveFeeOwed;
        f.reserveFeeCollected = true;
        totalReserveFundCollected += amount;

        if (amount > 0) {
            wlpToken.safeTransfer(reserveFundWallet, amount);
        }

        emit ReserveFundCollected(rorContract, tokenId, financingId, amount, reserveFundWallet);
    }

    /**
     * @notice Update the reserve fund wallet (owner only).
     * @param newWallet New reserve fund wallet address
     */
    function setReserveFundWallet(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert InvalidAddress();
        if (newWallet == feeWallet) revert InvalidAddress();
        address oldWallet = reserveFundWallet;
        reserveFundWallet = newWallet;
        emit ReserveFundWalletUpdated(oldWallet, newWallet);
    }

    /**
     * @notice Set the maximum pool size (WLP amount cap)
     * @param newSize New max pool size in WLP (18 decimals)
     */
    function setMaxPoolSize(uint256 newSize) external onlyOwner {
        if (newSize == 0) revert InvalidAmount();

        uint256 oldSize = maxPoolSize;
        maxPoolSize = newSize;

        emit MaxPoolSizeUpdated(oldSize, newSize);
    }

    /**
     * @notice Set the WTKN token address (one-time setup or upgrade)
     * @param _wtknToken WTKN ERC20 token address
     */
    function setWTKNToken(address _wtknToken) external onlyOwner {
        if (_wtknToken == address(0)) revert InvalidAddress();
        wtknToken = IERC20(_wtknToken);
    }

    /**
     * @notice Return WTKN to buyer after settlement
     * @dev Called after releaseWTKNToAllHolders sends WTKN to this contract
     * @param buyer Buyer wallet address to return WTKN to
     * @param amount WTKN amount to return
     */
    function returnWTKNToBuyer(address buyer, uint256 amount) external onlyOwner whenNotPaused {
        if (buyer == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (address(wtknToken) == address(0)) revert InvalidAddress();

        wtknToken.safeTransfer(buyer, amount);

        emit WTKNReturnedToBuyer(buyer, amount);
    }

    /**
     * @notice Burn ROR tokens held by this contract after settlement
     * @param rorContract ROR ERC1155 contract address
     * @param tokenId ROR token ID to burn
     */
    function burnROR(address rorContract, uint256 tokenId) external onlyOwner whenNotPaused {
        if (rorContract == address(0)) revert InvalidAddress();

        IERC1155 ror = IERC1155(rorContract);
        uint256 balance = ror.balanceOf(address(this), tokenId);
        if (balance == 0) revert InvalidAmount();

        // Call burn on the ROR contract (assumes burnRORBatch interface)
        // Using low-level call since burn interface may vary
        (bool success, ) = rorContract.call(
            abi.encodeWithSignature("burnRORBatch(uint256[])", _toArray(tokenId))
        );
        require(success, "ROR burn failed");

        emit RORBurned(rorContract, tokenId, balance);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    OWNER CONFIG SETTERS
    // ═══════════════════════════════════════════════════════════════

    function setLockUpDuration(uint256 newDuration) external onlyOwner {
        uint256 oldDuration = lockUpDuration;
        lockUpDuration = newDuration;
        emit LockUpDurationUpdated(oldDuration, newDuration);
    }

    function setMaxUtilisationBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > 10000) revert InvalidBps();
        uint256 oldBps = maxUtilisationBps;
        maxUtilisationBps = newBps;
        emit MaxUtilisationUpdated(oldBps, newBps);
    }

    function setEarlyExitPenaltyBps(uint256 newBps) external onlyOwner {
        if (newBps > 5000) revert InvalidBps(); // Max 50%
        uint256 oldBps = earlyExitPenaltyBps;
        earlyExitPenaltyBps = newBps;
        emit EarlyExitPenaltyUpdated(oldBps, newBps);
    }

    function setFeeWallet(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert InvalidAddress();
        address oldWallet = feeWallet;
        feeWallet = newWallet;
        emit FeeWalletUpdated(oldWallet, newWallet);
    }

    function setMinimumAllocation(uint256 newMinimum) external onlyOwner {
        uint256 oldMinimum = minimumAllocation;
        minimumAllocation = newMinimum;
        emit MinimumAllocationUpdated(oldMinimum, newMinimum);
    }

    /**
     * @notice Add or remove a single investor from the allocation allowlist
     * @param investor Investor address to update
     * @param status True to whitelist, false to remove
     */
    function setWhitelist(address investor, bool status) external onlyOwner {
        if (investor == address(0)) revert InvalidAddress();
        isWhitelisted[investor] = status;
        emit WhitelistUpdated(investor, status);
    }

    /**
     * @notice Add or remove many investors from the allowlist in one call
     * @param investors Investor addresses to update
     * @param status True to whitelist all, false to remove all
     */
    function setWhitelistBatch(address[] calldata investors, bool status) external onlyOwner {
        for (uint256 i = 0; i < investors.length; i++) {
            if (investors[i] == address(0)) revert InvalidAddress();
            isWhitelisted[investors[i]] = status;
            emit WhitelistUpdated(investors[i], status);
        }
    }

    /**
     * @notice Enable or disable allowlist enforcement on allocate()
     * @dev When disabled, any address may allocate (original behaviour)
     * @param enabled True to enforce the allowlist, false to allow all
     */
    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    /**
     * @notice Create a new Series with its own lock-up and allocation window
     * @param name Human-readable label e.g. "Series A"
     * @param lockUpSeconds Lock-up duration for investors in this series
     * @param startDate Unix timestamp when allocation window opens
     * @param endDate Unix timestamp when allocation window closes (0 = no end)
     * @param maxSize Maximum WLP this series accepts (0 = unlimited)
     * @param minAllocation Minimum WLP per investor (0 = no minimum)
     * @return seriesId The ID assigned to the new series
     */
    function createSeries(
        string calldata name,
        uint256 lockUpSeconds,
        uint256 startDate,
        uint256 endDate,
        uint256 maxSize,
        uint256 minAllocation
    ) external onlyOwner returns (uint256 seriesId) {
        if (lockUpSeconds == 0) revert InvalidSeriesConfig();
        if (bytes(name).length == 0) revert InvalidSeriesConfig();
        if (endDate > 0 && endDate <= startDate) revert InvalidSeriesConfig();

        seriesId = ++seriesCount;

        seriesRegistry[seriesId] = Series({
            name: name,
            lockUpSeconds: lockUpSeconds,
            startDate: startDate,
            endDate: endDate,
            maxSize: maxSize,
            minAllocation: minAllocation,
            totalAllocated: 0,
            active: true
        });

        emit SeriesCreated(seriesId, name, lockUpSeconds, startDate, endDate, maxSize);
    }

    /**
     * @notice Update an existing series' allocation window and size caps
     * @dev lockUpSeconds cannot be changed after creation to protect existing allocations
     * @param seriesId Series to update
     * @param startDate New start date (0 = keep existing)
     * @param endDate New end date (0 = no end)
     * @param maxSize New max size (0 = unlimited)
     * @param minAllocation New minimum per investor (0 = no minimum)
     */
    function updateSeries(
        uint256 seriesId,
        uint256 startDate,
        uint256 endDate,
        uint256 maxSize,
        uint256 minAllocation
    ) external onlyOwner {
        Series storage s = seriesRegistry[seriesId];
        if (s.lockUpSeconds == 0) revert SeriesNotFound(seriesId);

        // startDate == 0 is the documented "keep existing" sentinel. Honor it so
        // routine updates to other fields don't overwrite startDate with the Unix
        // epoch, which allocate() would treat as immediately open and could reopen
        // a future-dated series before its intended launch.
        uint256 newStartDate = startDate == 0 ? s.startDate : startDate;
        if (endDate > 0 && endDate <= newStartDate) revert InvalidSeriesConfig();

        s.startDate = newStartDate;
        s.endDate = endDate;
        s.maxSize = maxSize;
        s.minAllocation = minAllocation;

        emit SeriesUpdated(seriesId, newStartDate, endDate, maxSize, minAllocation);
    }

    /**
     * @notice Deactivate a series — stops new allocations immediately
     * @param seriesId Series to deactivate
     */
    function deactivateSeries(uint256 seriesId) external onlyOwner {
        Series storage s = seriesRegistry[seriesId];
        if (s.lockUpSeconds == 0) revert SeriesNotFound(seriesId);
        s.active = false;
        emit SeriesDeactivated(seriesId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════
    //                 MIGRATION / RECOVERY  (owner only)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice One-time migration entrypoint, run atomically during an upgrade via
     *         upgradeToAndCall(newImpl, abi.encodeCall(SubPool.migrateV2, ())).
     * @dev This implementation adds recovery functions only (no new storage), so the
     *      body is just a version marker. The PATTERN is the point: every future
     *      upgrade that changes storage or an on-chain index MUST perform its backfill
     *      here and be invoked with this calldata — never upgradeToAndCall(impl, "").
     *      onlyOwner + reinitializer(2) => runs exactly once, only by the owner.
     */
    function migrateV2() external onlyOwner reinitializer(2) {
        emit Migrated(2);
    }

    /**
     * @notice Rebuild the on-chain tracking for a financing that exists off-chain
     *         (real WLP was deployed) but is missing from this implementation's
     *         index — e.g. a financing created by a prior implementation before an
     *         upgrade introduced tokenActiveFinancings/nextFinancingId and was never
     *         backfilled, so receiveSettlement reverts FinancingNotFound. Restores
     *         financings[key], tokenActiveFinancings and nextFinancingId so a normal
     *         receiveSettlement / recordDefault can close it.
     * @dev Values MUST come from the trusted off-chain record of the original
     *      financing (the same numbers passed to the original financeSupplier). This
     *      moves NO WLP. Idempotent: reverts if a record already exists for the key.
     * @param addToOutstanding Whether to add faceValue to totalFinancedOutstanding.
     *      Pass FALSE when the prior implementation already counted it in the
     *      (storage-preserved) totalFinancedOutstanding — the normal post-upgrade
     *      case, where receiveSettlement's `-= faceValue` must balance. Pass TRUE
     *      only if the outstanding accumulator does not already include it. If in
     *      doubt, reindex FALSE and set the accumulator via adminReconcileOutstanding.
     */
    function adminReindexFinancing(
        address rorContract,
        uint256 tokenId,
        uint256 financingId,
        uint256 wlpDeployed,
        uint256 faceValue,
        uint256 financedAt,
        uint256 platformFeeOwed,
        uint256 reserveFeeOwed,
        bool addToOutstanding
    ) external onlyOwner {
        if (rorContract == address(0)) revert InvalidAddress();
        if (faceValue == 0 || financedAt == 0) revert InvalidAmount();

        bytes32 key = _financingKey(rorContract, tokenId, financingId);
        // financedAt doubles as the existence marker (see collectPlatformFee).
        if (financings[key].financedAt != 0) revert FinancingAlreadyExists(key);

        financings[key] = FinancingRecord({
            rorContract: rorContract,
            rorTokenId: tokenId,
            financingId: financingId,
            wlpDeployed: wlpDeployed,
            faceValue: faceValue,
            financedAt: financedAt,
            platformFeeOwed: platformFeeOwed,
            reserveFeeOwed: reserveFeeOwed,
            settled: false,
            defaulted: false,
            platformFeeCollected: false,
            reserveFeeCollected: false
        });

        bytes32 tKey = _tokenKey(rorContract, tokenId);
        tokenActiveFinancings[tKey].push(financingId);
        if (financingId > nextFinancingId[tKey]) {
            nextFinancingId[tKey] = financingId;
        }

        if (addToOutstanding) {
            totalFinancedOutstanding += faceValue;
        }

        emit FinancingReindexed(rorContract, tokenId, financingId, faceValue);
    }

    /**
     * @notice Set totalFinancedOutstanding to a reconciled absolute value.
     * @dev Escape hatch for pools whose outstanding accumulator has drifted from the
     *      true sum of open financings (e.g. from partially-applied operations before
     *      a fix). correctValue MUST be computed off-chain as the sum of faceValue
     *      over all currently-open (unsettled, non-defaulted) financings. Prefer
     *      adminReindexFinancing; use this only to correct an already-drifted total.
     */
    function adminReconcileOutstanding(uint256 correctValue) external onlyOwner {
        uint256 oldValue = totalFinancedOutstanding;
        totalFinancedOutstanding = correctValue;
        emit OutstandingReconciled(oldValue, correctValue);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Get total pool value (available + financed outstanding)
     */
    function totalPoolValue() external view returns (uint256) {
        return totalWlpBalance + totalFinancedOutstanding;
    }

    /**
     * @notice Get current utilisation in basis points
     */
    function currentUtilisationBps() external view returns (uint256) {
        uint256 total = totalWlpBalance + totalFinancedOutstanding;
        if (total == 0) return 0;
        return (totalFinancedOutstanding * 10000) / total;
    }

    /**
     * @notice Get remaining WLP capacity before pool size cap is reached
     */
    function availableCapacity() external view returns (uint256) {
        uint256 currentSize = totalWlpBalance + totalFinancedOutstanding;
        if (currentSize >= maxPoolSize) return 0;
        return maxPoolSize - currentSize;
    }

    /**
     * @notice Get number of allocations for an investor
     */
    function allocationCount(address investor) external view returns (uint256) {
        return _allocations[investor].length;
    }

    /**
     * @notice Get a specific allocation for an investor
     */
    function getAllocation(address investor, uint256 index) external view returns (Allocation memory) {
        if (index >= _allocations[investor].length) revert AllocationIndexOutOfBounds();
        return _allocations[investor][index];
    }

    /**
     * @notice Get redeemable units for an investor (past lock-up, not yet redeemed)
     */
    function redeemableUnits(address investor) external view returns (uint256 total) {
        Allocation[] storage allocs = _allocations[investor];
        for (uint256 i = 0; i < allocs.length; i++) {
            if (!allocs[i].redeemed && block.timestamp >= allocs[i].lockUpEndsAt) {
                total += allocs[i].unitsIssued;
            }
        }
    }

    /**
     * @notice Get locked units for an investor (within lock-up, not yet redeemed)
     */
    function lockedUnits(address investor) external view returns (uint256 total) {
        Allocation[] storage allocs = _allocations[investor];
        for (uint256 i = 0; i < allocs.length; i++) {
            if (!allocs[i].redeemed && block.timestamp < allocs[i].lockUpEndsAt) {
                total += allocs[i].unitsIssued;
            }
        }
    }

    /**
     * @notice Get a financing record by its key
     */
    function getFinancingKey(address rorContract, uint256 tokenId, uint256 financingId)
        external
        pure
        returns (bytes32)
    {
        return _financingKey(rorContract, tokenId, financingId);
    }

    /**
     * @notice Get series details by ID
     */
    function getSeries(uint256 seriesId) external view returns (Series memory) {
        if (seriesRegistry[seriesId].lockUpSeconds == 0) revert SeriesNotFound(seriesId);
        return seriesRegistry[seriesId];
    }

    /**
     * @notice Get implementation version
     */
    function version() public pure virtual returns (string memory) {
        return "1.5.0";
    }

    // ═══════════════════════════════════════════════════════════════
    //                     INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Internal redeem logic shared by redeem() and redeemEarly()
     */
    function _redeem(address investor, uint256 allocationIndex, bool early) internal {
        if (allocationIndex >= _allocations[investor].length) revert AllocationIndexOutOfBounds();

        Allocation storage alloc = _allocations[investor][allocationIndex];
        if (alloc.redeemed) revert AllocationAlreadyRedeemed();

        // Check lock-up unless early redemption
        if (!early && block.timestamp < alloc.lockUpEndsAt) {
            revert LockUpNotExpired(alloc.lockUpEndsAt);
        }

        uint256 units = alloc.unitsIssued;

        // Calculate WLP to return: wlpReturn = units * currentNav / 1e18
        uint256 wlpToReturn = (units * currentNav) / 1e18;

        // Apply early exit penalty if applicable
        if (early && earlyExitPenaltyBps > 0) {
            uint256 penalty = (wlpToReturn * earlyExitPenaltyBps + 9999) / 10000;
            wlpToReturn -= penalty;
            // Penalty stays in the pool (benefits remaining investors via NAV)
        }

        // Check sufficient liquidity
        if (totalWlpBalance < wlpToReturn) {
            revert InsufficientLiquidity(totalWlpBalance, wlpToReturn);
        }

        // Mark allocation as redeemed
        alloc.redeemed = true;

        // Burn units from investor (permanently cancelled on-chain)
        unitBalanceOf[investor] -= units;
        totalUnitsInCirculation -= units;

        // Transfer WLP to investor
        totalWlpBalance -= wlpToReturn;

        wlpToken.safeTransfer(investor, wlpToReturn);

        emit Redeemed(investor, units, wlpToReturn, allocationIndex, early);
    }

    /**
     * @dev Generate a unique key for a financing record. Includes financingId so
     *      a single token can be financed repeatedly without key collisions.
     */
    function _financingKey(address rorContract, uint256 tokenId, uint256 financingId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rorContract, tokenId, financingId));
    }

    /**
     * @dev Token-scoped key used to index all financings on a given token.
     */
    function _tokenKey(address rorContract, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encode(rorContract, tokenId));
    }

    /**
     * @dev Helper to create a single-element uint256 array
     */
    function _toArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = value;
        return arr;
    }

    /**
     * @dev Authorize upgrade (only owner)
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert InvalidAddress();
    }
}
