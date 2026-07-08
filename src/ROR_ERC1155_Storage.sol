// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IROR_ERC1155.sol";
import "./libraries/RORPermissions.sol";

/**
 * @title IWTKN
 * @notice Minimal interface for WTKN token interaction
 */
interface IWTKN is IERC20 {
    function anchorBuyer() external view returns (address);
    function recordStake(uint256 rorTokenId, uint256 amount) external;
    function recordUnstake(uint256 rorTokenId, uint256 amount) external;
}

/**
 * @title ROR_ERC1155_Storage
 * @notice Abstract storage layout for ROR_ERC1155_V2
 * @dev Minimal on-chain state for execution guards only.
 *      All metadata is emitted via events — no on-chain metadata storage.
 */
abstract contract ROR_ERC1155_Storage is
    Initializable,
    ERC1155Upgradeable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============ Permission Library ============
    bytes32 public constant ADMIN_ROLE = RORPermissions.ADMIN_ROLE;
    bytes32 public constant MINTER_ROLE = RORPermissions.MINTER_ROLE;
    bytes32 public constant UPGRADER_ROLE = RORPermissions.UPGRADER_ROLE;
    bytes32 public constant CRONJOB_ROLE = RORPermissions.CRONJOB_ROLE;

    // ============ Constants ============
    uint256 internal constant MIN_TOKEN_ID = 1000;

    // ============ Structs (minimal execution guards) ============

    struct TokenState {
        IROR_ERC1155.RoRStatus status;
        bool isSettled;
        uint256 nextFinancingId;
    }

    struct SupplierState {
        uint8 tier;
        bool hasFinanced;
    }

    struct WTKNStake {
        address wtknContract;
        uint256 amount;
        uint256 expiryDate;
        bool isReleased;
        bool maturityReached;
        uint256 totalReleased;
        mapping(address => uint256) releasedAmounts;
    }

    // ============ Storage ============
    uint256 internal _tokenIdCounter;
    string internal _name;
    string internal _symbol;

    mapping(uint256 => TokenState) internal tokenState;
    mapping(uint256 => mapping(address => SupplierState)) internal supplierState;
    mapping(uint256 => WTKNStake) internal wtknStakes;
    mapping(address => address) public buyerToWTKN;

    // Holder tracking (needed for WTKN release pagination)
    mapping(uint256 => address[]) internal _holders;
    mapping(uint256 => mapping(address => bool)) internal _isHolder;
    mapping(uint256 => mapping(address => bool)) internal _hasClaimed;
    // 1-based index of each holder in _holders[tokenId]; 0 = not present.
    // Enables O(1) swap-and-pop removal without a linear scan.
    mapping(uint256 => mapping(address => uint256)) internal _holderIndexPlusOne;
    // WTKN amounts that failed to transfer and are awaiting a manual retry.
    // Non-zero means releasedAmounts[holder] is already set (main loop skips them).
    mapping(uint256 => mapping(address => uint256)) internal _pendingWTKNRelease;

    // ============ Storage Gap ============
    uint256[42] private __gap;

    // ============ Internal Helpers ============

    function _addHolder(uint256 tokenId, address holder) internal {
        if (!_isHolder[tokenId][holder]) {
            _holders[tokenId].push(holder);
            _holderIndexPlusOne[tokenId][holder] = _holders[tokenId].length; // 1-based
            _isHolder[tokenId][holder] = true;
        }
    }

    // O(1) swap-and-pop removal. Callers must ensure the holder's balance is
    // about to reach (or has already reached) zero before calling.
    function _removeHolder(uint256 tokenId, address holder) internal {
        if (!_isHolder[tokenId][holder]) return;
        address[] storage arr = _holders[tokenId];
        uint256 idx = _holderIndexPlusOne[tokenId][holder] - 1; // convert to 0-based
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            address last = arr[lastIdx];
            arr[idx] = last;
            _holderIndexPlusOne[tokenId][last] = idx + 1; // update moved element
        }
        arr.pop();
        _holderIndexPlusOne[tokenId][holder] = 0;
        _isHolder[tokenId][holder] = false;
    }

    function _updateStatus(uint256 tokenId, IROR_ERC1155.RoRStatus newStatus) internal {
        IROR_ERC1155.RoRStatus oldStatus = tokenState[tokenId].status;
        tokenState[tokenId].status = newStatus;
        emit IROR_ERC1155.RORStatusUpdated(tokenId, oldStatus, newStatus);
    }

    // ============ Required OZ Overrides ============

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
