// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISubPool
 * @notice External interface of SubPool v1.9.0, generated from its ABI
 *         (`forge inspect SubPool abi` → `cast interface`). Regenerate it when
 *         SubPool's external surface changes; do not edit by hand.
 */
interface ISubPool {
    struct Allocation {
        uint256 wlpAmount;
        uint256 unitsIssued;
        uint256 allocatedAt;
        uint256 lockUpEndsAt;
        bool redeemed;
        uint8 investmentType;
        uint256 seriesId;
    }

    struct Series {
        string name;
        uint256 lockUpSeconds;
        uint256 startDate;
        uint256 endDate;
        uint256 maxSize;
        uint256 minAllocation;
        uint256 totalAllocated;
        bool active;
    }

    error AllocationAlreadyRedeemed();
    error AllocationIndexOutOfBounds();
    error AmountPrecision(uint256 amount);
    error BelowMinimumAllocation(uint256 amount, uint256 minimum);
    error EntryNavAlreadySet(uint256 seriesId);
    error EntryNavNotSet(uint256 seriesId);
    error FeesAlreadyCollected(bytes32 key);
    error FinancingAlreadyDefaulted(bytes32 key);
    error FinancingAlreadyExists(bytes32 key);
    error FinancingAlreadySettled(bytes32 key);
    error FinancingNotFound(bytes32 key);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error InsufficientRemainingUnits(uint256 remaining, uint256 requested);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidBps();
    error InvalidSeriesConfig();
    error LegacyTermsNotAllowed(uint256 seriesId);
    error LegacyTermsRequired(uint256 seriesId);
    error LockUpNotExpired(uint256 lockUpEndsAt);
    error NavNotSet();
    error NavPrecision(uint256 nav);
    error NotSeriesAllocation();
    error NotWhitelisted(address investor);
    error PoolSizeExceeded(uint256 newSize, uint256 maxSize);
    error ReserveFeeDisabled();
    error SafeERC20FailedOperation(address token);
    error SeriesAllocationClosed(uint256 seriesId, uint256 closesAt);
    error SeriesEnded(uint256 seriesId, uint256 endDate);
    error SeriesMaturityNavAlreadyFixed(uint256 seriesId);
    error SeriesMaturityNavNotFixed(uint256 seriesId);
    error SeriesMaxSizeExceeded(uint256 seriesId, uint256 available, uint256 requested);
    error SeriesNavStale(uint256 navTimestamp, uint256 maturity);
    error SeriesNirAlreadySet(uint256 seriesId);
    error SeriesNirNotSet(uint256 seriesId);
    error SeriesNotActive(uint256 seriesId);
    error SeriesNotFound(uint256 seriesId);
    error SeriesNotMatured(uint256 seriesId, uint256 maturity);
    error SeriesNotStarted(uint256 seriesId, uint256 startDate);
    error SeriesTermsFrozen(uint256 seriesId);
    error UseRedeemSeries();
    error UtilisationExceeded(uint256 currentUtilisation, uint256 maxUtilisation);

    event AdminChanged(address previousAdmin, address newAdmin);
    event Allocated(
        address indexed investor,
        uint256 wlpAmount,
        uint256 unitsIssued,
        uint256 allocationIndex,
        uint256 lockUpEndsAt,
        uint8 investmentType
    );
    event BeaconUpgraded(address indexed beacon);
    event DefaultRecorded(address indexed rorContract, uint256 indexed tokenId, uint256 lossAmount);
    event EarlyExitPenaltyUpdated(uint256 oldBps, uint256 newBps);
    event FeeWalletUpdated(address oldWallet, address newWallet);
    event FinancingReindexed(
        address indexed rorContract, uint256 indexed tokenId, uint256 financingId, uint256 faceValue
    );
    event Initialized(uint8 version);
    event InterestReceived(uint256 wlpAmount);
    event LockUpDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MaxPoolSizeUpdated(uint256 oldSize, uint256 newSize);
    event MaxUtilisationUpdated(uint256 oldBps, uint256 newBps);
    event Migrated(uint64 version);
    event MinimumAllocationUpdated(uint256 oldAmount, uint256 newAmount);
    event NavChangeAlert(uint256 previousNav, uint256 newNav, uint256 changeBps);
    event NavUpdated(uint256 newNav, uint256 timestamp);
    event OutstandingReconciled(uint256 oldValue, uint256 newValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event PlatformFeeCollected(
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 indexed financingId,
        uint256 amount,
        address feeWallet
    );
    event RORBurned(address indexed rorContract, uint256 indexed tokenId, uint256 amount);
    event Redeemed(
        address indexed investor,
        uint256 unitsReturned,
        uint256 wlpReturned,
        uint256 allocationIndex,
        bool early,
        uint256 remainingUnits
    );
    event ReserveFeeReleasedToPool(
        address indexed rorContract, uint256 indexed tokenId, uint256 indexed financingId, uint256 amount
    );
    event ReserveFundCollected(
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 indexed financingId,
        uint256 amount,
        address reserveFundWallet
    );
    event ReserveFundWalletUpdated(address oldWallet, address newWallet);
    event SeriesCreated(
        uint256 indexed seriesId,
        string name,
        uint256 lockUpSeconds,
        uint256 startDate,
        uint256 endDate,
        uint256 maxSize
    );
    event SeriesDeactivated(uint256 indexed seriesId);
    event SeriesEntryNavSet(uint256 indexed seriesId, uint256 entryNav);
    event SeriesLegacyTermsSet(uint256 indexed seriesId, uint256 nirBps, uint256 entryNav, uint256 maturityNav);
    event SeriesMaturityNavFixed(uint256 indexed seriesId, uint256 maturityNav);
    event SeriesNirSet(uint256 indexed seriesId, uint256 nirBps);
    event SeriesRedeemed(
        address indexed investor,
        uint256 allocationIndex,
        uint256 indexed seriesId,
        uint256 units,
        uint256 pricePerUnit,
        uint256 wlpPaid,
        uint256 remainingUnits
    );
    event SeriesUpdated(
        uint256 indexed seriesId, uint256 startDate, uint256 endDate, uint256 maxSize, uint256 minAllocation
    );
    event SettlementReceived(address indexed rorContract, uint256 indexed tokenId, uint256 wlpAmount);
    event SupplierFinanced(
        address indexed supplier,
        address indexed rorContract,
        uint256 indexed tokenId,
        uint256 financingId,
        uint256 wlpAmount,
        uint256 faceValue
    );
    event Unpaused(address account);
    event Upgraded(address indexed implementation);
    event WTKNReturnedToBuyer(address indexed buyer, uint256 amount);
    event WhitelistToggled(bool enabled);
    event WhitelistUpdated(address indexed investor, bool status);

    function SERIES_ALLOCATION_WINDOW() external view returns (uint256);
    function UNIT_DECIMALS() external view returns (uint8);
    function adminReconcileOutstanding(uint256 correctValue) external;
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
    ) external;
    function adminSetSeriesLegacyTerms(uint256 seriesId, uint256 nirBps, uint256 entryNav, uint256 maturityNav) external;
    function allocate(uint256 wlpAmount, uint8 investmentType, uint256 seriesId) external;
    function allocationCount(address investor) external view returns (uint256);
    function availableCapacity() external view returns (uint256);
    function burnROR(address rorContract, uint256 tokenId) external;
    function collectPlatformFee(address rorContract, uint256 tokenId, uint256 financingId) external;
    function collectReserveFund(address rorContract, uint256 tokenId, uint256 financingId) external;
    function createSeries(
        string memory name,
        uint256 lockUpSeconds,
        uint256 startDate,
        uint256 endDate,
        uint256 maxSize,
        uint256 minAllocation
    ) external returns (uint256 seriesId);
    function currentNav() external view returns (uint256);
    function currentUtilisationBps() external view returns (uint256);
    function deactivateSeries(uint256 seriesId) external;
    function earlyExitPenaltyBps() external view returns (uint256);
    function feeWallet() external view returns (address);
    function financeSupplier(
        address supplier,
        address rorContract,
        uint256 tokenId,
        uint256 wlpAmount,
        uint256 faceValue,
        uint256 platformFee,
        uint256 reserveFee
    ) external returns (uint256 financingId);
    function financings(bytes32)
        external
        view
        returns (
            address rorContract,
            uint256 rorTokenId,
            uint256 wlpDeployed,
            uint256 faceValue,
            uint256 financedAt,
            bool settled,
            bool defaulted,
            uint256 financingId,
            uint256 platformFeeOwed,
            uint256 reserveFeeOwed,
            bool platformFeeCollected,
            bool reserveFeeCollected
        );
    function fixSeriesMaturityNav(uint256 seriesId) external;
    function getAllocation(address investor, uint256 index) external view returns (Allocation memory);
    function getFinancingKey(address rorContract, uint256 tokenId, uint256 financingId) external pure returns (bytes32);
    function getSeries(uint256 seriesId) external view returns (Series memory);
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
    ) external;
    function initializedVersion() external view returns (uint64);
    function isWhitelisted(address) external view returns (bool);
    function lockUpDuration() external view returns (uint256);
    function lockedUnits(address investor) external view returns (uint256 total);
    function maxPoolSize() external view returns (uint256);
    function maxUtilisationBps() external view returns (uint256);
    function migrateV2() external;
    function migrateV3() external;
    function migrateV4() external;
    function migrateV5() external;
    function minimumAllocation() external view returns (uint256);
    function navTimestamp() external view returns (uint256);
    function nextFinancingId(bytes32) external view returns (uint256);
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        external
        returns (bytes4);
    function onERC1155Received(address, address, uint256, uint256, bytes memory) external returns (bytes4);
    function owner() external view returns (address);
    function pause() external;
    function paused() external view returns (bool);
    function poolName() external view returns (string memory);
    function proxiableUUID() external view returns (bytes32);
    function receiveInterest(uint256 wlpAmount) external;
    function receiveSettlement(address rorContract, uint256 tokenId, uint256 wlpAmount) external;
    function recordDefault(address rorContract, uint256 tokenId, uint256 lossAmount) external;
    function redeem(uint256 allocationIndex, uint256 amount) external;
    function redeem(uint256 allocationIndex) external;
    function redeemEarly(uint256 allocationIndex) external;
    function redeemEarly(uint256 allocationIndex, uint256 amount) external;
    function redeemSeries(address investor, uint256 allocationIndex, uint256 units) external;
    function redeemableUnits(address investor) external view returns (uint256 total);
    function releaseReserveFeeToPool(address rorContract, uint256 tokenId, uint256 financingId) external;
    function renounceOwnership() external;
    function reserveFundWallet() external view returns (address);
    function returnWTKNToBuyer(address buyer, uint256 amount) external;
    function seriesCount() external view returns (uint256);
    function seriesEntryNav(uint256) external view returns (uint256);
    function seriesMaturityNav(uint256) external view returns (uint256);
    function seriesMaxRedemptionPrice(uint256 seriesId) external view returns (uint256);
    function seriesNirBps(uint256) external view returns (uint256);
    function seriesRedemptionQuote(address investor, uint256 allocationIndex)
        external
        view
        returns (uint256 mrp, uint256 maturityNav, uint256 price, uint256 remainingUnits, uint256 wlpDue);
    function seriesRegistry(uint256)
        external
        view
        returns (
            string memory name,
            uint256 lockUpSeconds,
            uint256 startDate,
            uint256 endDate,
            uint256 maxSize,
            uint256 minAllocation,
            uint256 totalAllocated,
            bool active
        );
    function setEarlyExitPenaltyBps(uint256 newBps) external;
    function setFeeWallet(address newWallet) external;
    function setLockUpDuration(uint256 newDuration) external;
    function setMaxPoolSize(uint256 newSize) external;
    function setMaxUtilisationBps(uint256 newBps) external;
    function setMinimumAllocation(uint256 newMinimum) external;
    function setReserveFundWallet(address newWallet) external;
    function setSeriesEntryNav(uint256 seriesId, uint256 entryNav) external;
    function setSeriesNir(uint256 seriesId, uint256 nirBps) external;
    function setWTKNToken(address _wtknToken) external;
    function setWhitelist(address investor, bool status) external;
    function setWhitelistBatch(address[] memory investors, bool status) external;
    function setWhitelistEnabled(bool enabled) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function totalFinancedOutstanding() external view returns (uint256);
    function totalPlatformFeesCollected() external view returns (uint256);
    function totalPoolValue() external view returns (uint256);
    function totalReserveFundCollected() external view returns (uint256);
    function totalUnitsInCirculation() external view returns (uint256);
    function totalWlpBalance() external view returns (uint256);
    function transferOwnership(address newOwner) external;
    function unitBalanceOf(address) external view returns (uint256);
    function unitName() external view returns (string memory);
    function unitSymbol() external view returns (string memory);
    function unitsRedeemedOf(address, uint256) external view returns (uint256);
    function unpause() external;
    function updateNav(uint256 newNav) external;
    function updateSeries(uint256 seriesId, uint256 startDate, uint256 endDate, uint256 maxSize, uint256 minAllocation)
        external;
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
    function version() external pure returns (string memory);
    function whitelistEnabled() external view returns (bool);
    function wlpToken() external view returns (address);
    function wtknToken() external view returns (address);
}
