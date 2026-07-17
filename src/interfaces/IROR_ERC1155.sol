// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IROR_ERC1155
 * @notice Interface for ROR ERC1155 multi-tier deep supply chain financing token
 * @dev All metadata is emitted via events — no on-chain metadata storage.
 */
interface IROR_ERC1155 {

    // ============ Enums ============

    enum RoRStatus {
        CREATED,
        BUYER_CONFIRMED,
        FINANCIER_APPROVED,
        FINANCED,
        MATURED,
        SETTLED,
        EXPIRED,
        DISPUTED
    }

    enum FeePaymentTiming {
        AT_FINANCING,
        AT_SETTLEMENT,
        DEFERRED
    }

    // ============ Structs (calldata-only, not stored) ============

    struct FeeItem {
        uint256 feeId;
        string feeType;
        uint256 amount;
        address recipient;
        address payer;
        FeePaymentTiming timing;
        bool isPaid;
        uint256 paidAt;
    }

    // ============ Events ============

    event RORCreated(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed supplier,
        address anchorBuyer,
        uint256 amount,
        uint256 dueDate,
        string invoiceNumber
    );

    event RORTransferred(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event RORTransferredAsPayment(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to,
        uint256 amount,
        string downstreamInvoiceId,
        uint8 recipientTier
    );

    event RORFinanced(
        uint256 indexed tokenId,
        uint256 financingId,
        address indexed supplier,
        address indexed financier,
        uint256 amount,
        uint8 tier,
        uint256 totalFees
    );

    event FeeItemAdded(
        uint256 indexed tokenId,
        uint256 financingId,
        uint256 feeId,
        string feeType,
        uint256 amount,
        address recipient,
        address payer
    );

    event SupplierAdded(
        uint256 indexed tokenId,
        address indexed supplier,
        uint8 tier
    );

    event WTKNStaked(
        uint256 indexed tokenId,
        address indexed wtknContract,
        uint256 amount,
        uint256 expiryDate
    );

    event WTKNReleased(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount
    );

    event WTKNBatchReleased(
        uint256 indexed tokenId,
        uint256 holderCount,
        uint256 totalReleased
    );

    event WTKNReleaseRetryNeeded(
        uint256 indexed tokenId,
        address indexed holder,
        uint256 amount
    );

    event WTKNReleaseRedirected(
        uint256 indexed tokenId,
        address indexed holder,
        address indexed newRecipient,
        uint256 amount
    );

    event WTKNContractRegistered(
        address indexed buyer,
        address indexed wtknContract
    );

    event RORBurned(
        uint256 indexed tokenId,
        address indexed burner,
        uint256 amount
    );

    event RORStatusUpdated(
        uint256 indexed tokenId,
        RoRStatus oldStatus,
        RoRStatus newStatus
    );

    event FeesSettled(
        uint256 indexed tokenId,
        uint256 financingId,
        uint256 settledAt
    );

    // ============ Errors ============

    error InvalidTokenId();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidDueDate();
    error TokenNotMatured();
    error WTKNAlreadyReleased();
    error InsufficientRORBalance();
    error WTKNNotStaked();
    error NotTokenHolder();
    error InvalidStatus();
    error ExpiryDateNotReached();
    error WTKNNotReg();
    error Unauthorized();
    error InsufficientWTKNBal();
    error InsufficientWTKNAllow();
    error WTKNAlreadyReg();
    error EmptyInvoiceNumber();
    error SupplierIsBuyer();
    error TokenDoesNotExist();
    error NoPendingRelease(uint256 tokenId, address holder);
    error WTKNTransferFailed();
    error MustReleaseBefore();
    error InvalidStatusChange();
    error AllWTKNNotReleased();
    error TransferAfterMaturity();
    error InvalidFeeType();
    error InvalidFeeTiming();
    error InvalidFeePayer();
    error TotalFeeExceedsBalance();
    error SupplierNotFound();
    error TierMismatch(uint256 tokenId, address recipient, uint8 existingTier, uint8 expectedTier);
    error FinancingNotFound();
    error AlreadyFinanced();
    error EmptyFeesArray();
    error AlreadySettledFees();
    error InvoiceAmountTooSmall();

    // ============ Core Functions ============

    function initialize(address admin, string memory name_, string memory symbol_) external;

    function registerWTKNContract(address buyer, address wtknContract) external;

    function mintROR(
        address supplier,
        address anchorBuyer,
        uint256 invoiceAmount,
        uint256 dueDate,
        string memory invoiceNumber
    ) external returns (uint256);

    function transferRORAsPayment(
        uint256 tokenId,
        address to,
        uint256 amount,
        string calldata downstreamInvoiceId
    ) external;

    function financeMyRORBalance(
        uint256 tokenId,
        address financier,
        FeeItem[] calldata fees
    ) external returns (uint256);

    function releaseWTKNToAllHoldersPaginated(
        uint256 tokenId,
        uint256 startIndex,
        uint256 batchSize
    ) external returns (uint256 successCount, uint256 totalAmount);

    function burnRORBatch(uint256[] calldata tokenIds) external;

    function settleFees(uint256 tokenId, uint256 financingId) external;

    // ============ View Functions ============

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    function getWTKNStake(uint256 tokenId)
        external view returns (address wtknContract, uint256 amount, uint256 expiryDate, bool isReleased, bool maturityReached, uint256 totalReleased);

    function getReleasedAmount(uint256 tokenId, address holder) external view returns (uint256);

    function getMaturityStatus(uint256 tokenId) external view returns (bool isMatured, uint256 timeRemaining);

    function getHolders(uint256 tokenId)
        external view returns (address[] memory holders, uint256[] memory balances);
}
