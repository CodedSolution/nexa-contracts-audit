// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISubPool
 * @notice Interface for the SubPool investor liquidity pool contract
 */
interface ISubPool {
    // ─── Structs ───
    struct Allocation {
        uint256 wlpAmount;
        uint256 unitsIssued;
        uint256 allocatedAt;
        uint256 lockUpEndsAt;
        bool redeemed;
    }

    struct FinancingRecord {
        address rorContract;
        uint256 rorTokenId;
        uint256 wlpDeployed;
        uint256 faceValue;
        uint256 financedAt;
        bool settled;
        bool defaulted;
        uint256 financingId;
        uint256 platformFeeOwed;
        uint256 reserveFeeOwed;
        bool platformFeeCollected;
        bool reserveFeeCollected;
    }

    // ─── Events ───
    event NavUpdated(uint256 newNav, uint256 timestamp);
    event Allocated(address indexed investor, uint256 wlpAmount, uint256 unitsIssued, uint256 allocationIndex, uint256 lockUpEndsAt, uint8 investmentType);
    event Redeemed(address indexed investor, uint256 unitsReturned, uint256 wlpReturned, uint256 allocationIndex, bool early);
    event SupplierFinanced(address indexed supplier, address indexed rorContract, uint256 indexed tokenId, uint256 financingId, uint256 wlpAmount, uint256 faceValue);
    event SettlementReceived(address indexed rorContract, uint256 indexed tokenId, uint256 wlpAmount);
    event DefaultRecorded(address indexed rorContract, uint256 indexed tokenId, uint256 lossAmount);
    event PlatformFeeCollected(address indexed rorContract, uint256 indexed tokenId, uint256 indexed financingId, uint256 amount, address feeWallet);
    event ReserveFundCollected(address indexed rorContract, uint256 indexed tokenId, uint256 indexed financingId, uint256 amount, address reserveFundWallet);
    event ReserveFundWalletUpdated(address oldWallet, address newWallet);
    event MaxPoolSizeUpdated(uint256 oldSize, uint256 newSize);

    // ─── Investor Functions ───
    function allocate(uint256 wlpAmount, uint256 lockUpSeconds, uint8 investmentType) external;
    function redeem(uint256 allocationIndex) external;
    function redeemEarly(uint256 allocationIndex) external;

    // ─── Owner Functions ───
    function updateNav(uint256 newNav) external;
    function financeSupplier(address supplier, address rorContract, uint256 tokenId, uint256 wlpAmount, uint256 faceValue, uint256 platformFee, uint256 reserveFee) external returns (uint256 financingId);
    function nextFinancingId(bytes32 tokenKey) external view returns (uint256);
    function receiveSettlement(address rorContract, uint256 tokenId, uint256 wlpAmount) external;
    function recordDefault(address rorContract, uint256 tokenId, uint256 lossAmount) external;
    function collectPlatformFee(address rorContract, uint256 tokenId, uint256 financingId) external;
    function collectReserveFund(address rorContract, uint256 tokenId, uint256 financingId) external;
    function setMaxPoolSize(uint256 newSize) external;
    function setLockUpDuration(uint256 newDuration) external;
    function setMaxUtilisationBps(uint256 newBps) external;
    function setEarlyExitPenaltyBps(uint256 newBps) external;
    function setFeeWallet(address newWallet) external;
    function setReserveFundWallet(address newWallet) external;
    function setMinimumAllocation(uint256 newMinimum) external;
    function pause() external;
    function unpause() external;

    // ─── View Functions ───
    function poolName() external view returns (string memory);
    function currentNav() external view returns (uint256);
    function navTimestamp() external view returns (uint256);
    function totalWlpBalance() external view returns (uint256);
    function totalFinancedOutstanding() external view returns (uint256);
    function maxPoolSize() external view returns (uint256);
    function totalUnitsInCirculation() external view returns (uint256);
    function unitBalanceOf(address account) external view returns (uint256);
    function totalPoolValue() external view returns (uint256);
    function currentUtilisationBps() external view returns (uint256);
    function availableCapacity() external view returns (uint256);
    function allocationCount(address investor) external view returns (uint256);
    function getAllocation(address investor, uint256 index) external view returns (Allocation memory);
    function redeemableUnits(address investor) external view returns (uint256);
    function lockedUnits(address investor) external view returns (uint256);
    function getFinancingKey(address rorContract, uint256 tokenId, uint256 financingId) external pure returns (bytes32);
    function reserveFundWallet() external view returns (address);
    function totalReserveFundCollected() external view returns (uint256);
    function version() external pure returns (string memory);
}
