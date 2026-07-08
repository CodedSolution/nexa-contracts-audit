// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RORPermissions
 * @notice Permission constants library - Single source of truth for all ROR roles
 * @dev Following taas-web3 Permissions.sol pattern for centralized role definitions
 */
library RORPermissions {
    // Core Roles
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant CRONJOB_ROLE = keccak256("CRONJOB_ROLE");

    /// @notice Returns all role identifiers
    function getAllRoles() internal pure returns (bytes32[] memory list) {
        list = new bytes32[](4);
        list[0] = ADMIN_ROLE;
        list[1] = MINTER_ROLE;
        list[2] = UPGRADER_ROLE;
        list[3] = CRONJOB_ROLE;
    }
}
