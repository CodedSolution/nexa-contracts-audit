// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ROR_ERC1155_Storage.sol";

/**
 * @title ROR_ERC1155_V2
 * @notice ERC1155 multi-tier deep supply chain financing token with UUPS upgradeability
 * @dev Minimal on-chain state — all metadata emitted via events.
 *      Keeps only execution guards: tier, hasFinanced, status, WTKN stakes.
 */
contract ROR_ERC1155_V2 is ROR_ERC1155_Storage {

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address admin,
        string memory name_,
        string memory symbol_
    ) public initializer {
        if (admin == address(0)) revert IROR_ERC1155.InvalidAddress();

        __ERC1155_init("");
        __ERC1155Supply_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(CRONJOB_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        _tokenIdCounter = MIN_TOKEN_ID;
        _name = name_;
        _symbol = symbol_;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Configuration Functions ============

    function registerWTKNContract(address buyer, address wtknContract) external onlyRole(ADMIN_ROLE) {
        if (buyer == address(0) || wtknContract == address(0)) revert IROR_ERC1155.InvalidAddress();
        if (buyerToWTKN[buyer] != address(0)) revert IROR_ERC1155.WTKNAlreadyReg();

        buyerToWTKN[buyer] = wtknContract;
        emit IROR_ERC1155.WTKNContractRegistered(buyer, wtknContract);
    }

    // ============ Token Metadata ============

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    // ============ Core Functions - ROR Minting ============

    function mintROR(
        address supplier,
        address anchorBuyer,
        uint256 invoiceAmount,
        uint256 dueDate,
        string memory invoiceNumber
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        if (supplier == address(0) || anchorBuyer == address(0)) revert IROR_ERC1155.InvalidAddress();
        if (supplier == anchorBuyer) revert IROR_ERC1155.SupplierIsBuyer();
        if (invoiceAmount == 0) revert IROR_ERC1155.InvalidAmount();
        if (dueDate <= block.timestamp) revert IROR_ERC1155.InvalidDueDate();
        if (bytes(invoiceNumber).length == 0) revert IROR_ERC1155.EmptyInvoiceNumber();

        address wtknContract = buyerToWTKN[anchorBuyer];
        if (wtknContract == address(0)) revert IROR_ERC1155.WTKNNotReg();

        uint256 tokenId = _tokenIdCounter++;

        // Validate and stake WTKN
        IWTKN wtknToken = IWTKN(wtknContract);
        if (wtknToken.balanceOf(anchorBuyer) < invoiceAmount) revert IROR_ERC1155.InsufficientWTKNBal();
        if (wtknToken.allowance(anchorBuyer, address(this)) < invoiceAmount) revert IROR_ERC1155.InsufficientWTKNAllow();
        wtknToken.transferFrom(anchorBuyer, address(this), invoiceAmount);
        wtknToken.recordStake(tokenId, invoiceAmount);

        // Store WTKN stake (minimal)
        WTKNStake storage stake = wtknStakes[tokenId];
        stake.wtknContract = wtknContract;
        stake.amount = invoiceAmount;
        stake.expiryDate = dueDate;

        // Store token state (minimal)
        tokenState[tokenId].status = IROR_ERC1155.RoRStatus.CREATED;
        tokenState[tokenId].nextFinancingId = 1;

        // Store supplier state (minimal)
        supplierState[tokenId][supplier].tier = 1;

        // Mint ERC1155 tokens (1 ROR token per whole WTKN; sub-unit invoices are rejected)
        if (invoiceAmount < 10**18) revert IROR_ERC1155.InvoiceAmountTooSmall();
        uint256 rorAmount = invoiceAmount / 10**18;
        _mint(supplier, tokenId, rorAmount, "");

        // Events carry all metadata
        emit IROR_ERC1155.RORCreated(tokenId, msg.sender, supplier, anchorBuyer, invoiceAmount, dueDate, invoiceNumber);
        emit IROR_ERC1155.WTKNStaked(tokenId, wtknContract, invoiceAmount, dueDate);
        emit IROR_ERC1155.SupplierAdded(tokenId, supplier, 1);

        return tokenId;
    }

    // ============ Core Functions - Multi-Tier Transfers ============

    function transferRORAsPayment(
        uint256 tokenId,
        address to,
        uint256 amount,
        string calldata downstreamInvoiceId
    ) external nonReentrant {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();
        if (to == address(0)) revert IROR_ERC1155.InvalidAddress();
        if (amount == 0) revert IROR_ERC1155.InvalidAmount();
        if (bytes(downstreamInvoiceId).length == 0) revert IROR_ERC1155.EmptyInvoiceNumber();

        uint256 senderBalance = balanceOf(msg.sender, tokenId);
        if (senderBalance < amount) revert IROR_ERC1155.InsufficientRORBalance();

        // Check maturity restriction
        WTKNStake storage stake = wtknStakes[tokenId];
        if (stake.expiryDate > 0 && block.timestamp >= stake.expiryDate) {
            revert IROR_ERC1155.TransferAfterMaturity();
        }

        SupplierState storage senderState = supplierState[tokenId][msg.sender];
        if (senderState.tier == 0) revert IROR_ERC1155.SupplierNotFound();

        uint8 recipientTier = senderState.tier + 1;

        // Transfer ROR tokens
        _safeTransferFrom(msg.sender, to, tokenId, amount, "");

        // Set or validate recipient tier.
        // If recipient is new to this token, assign the expected tier.
        // If they already have a tier, it must exactly match sender.tier + 1 —
        // this blocks both backwards transfers and cross-tier shortcuts.
        SupplierState storage recipientState = supplierState[tokenId][to];
        if (recipientState.tier == 0) {
            recipientState.tier = recipientTier;
            emit IROR_ERC1155.SupplierAdded(tokenId, to, recipientTier);
        } else if (recipientState.tier != recipientTier) {
            revert IROR_ERC1155.TierMismatch(tokenId, to, recipientState.tier, recipientTier);
        }

        // Events carry all transfer metadata
        emit IROR_ERC1155.RORTransferredAsPayment(tokenId, msg.sender, to, amount, downstreamInvoiceId, recipientTier);
        emit IROR_ERC1155.RORTransferred(tokenId, msg.sender, to, amount);
    }

    // ============ Core Functions - Multi-Fee Financing ============

    function financeMyRORBalance(
        uint256 tokenId,
        address financier,
        IROR_ERC1155.FeeItem[] calldata fees
    ) external nonReentrant returns (uint256) {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();
        if (financier == address(0)) revert IROR_ERC1155.InvalidAddress();
        if (fees.length == 0) revert IROR_ERC1155.EmptyFeesArray();

        uint256 supplierBalance = balanceOf(msg.sender, tokenId);
        if (supplierBalance == 0) revert IROR_ERC1155.InsufficientRORBalance();

        // Check maturity restriction
        WTKNStake storage stake = wtknStakes[tokenId];
        if (stake.expiryDate > 0 && block.timestamp >= stake.expiryDate) {
            revert IROR_ERC1155.TransferAfterMaturity();
        }

        SupplierState storage sState = supplierState[tokenId][msg.sender];
        if (sState.tier == 0) revert IROR_ERC1155.SupplierNotFound();
        if (sState.hasFinanced) revert IROR_ERC1155.AlreadyFinanced();

        // Validate fees — split by timing
        uint256 totalAtFinancingFees = 0;
        uint256 totalDeferredFees = 0;
        for (uint256 i = 0; i < fees.length; i++) {
            IROR_ERC1155.FeeItem calldata fee = fees[i];
            if (fee.timing != IROR_ERC1155.FeePaymentTiming.AT_FINANCING &&
                fee.timing != IROR_ERC1155.FeePaymentTiming.AT_SETTLEMENT) revert IROR_ERC1155.InvalidFeeTiming();
            if (fee.payer != msg.sender) revert IROR_ERC1155.InvalidFeePayer();
            if (fee.recipient == address(0)) revert IROR_ERC1155.InvalidAddress();
            if (fee.amount == 0) revert IROR_ERC1155.InvalidAmount();
            if (fee.timing == IROR_ERC1155.FeePaymentTiming.AT_FINANCING) {
                totalAtFinancingFees += fee.amount;
            } else {
                totalDeferredFees += fee.amount;
            }
        }

        // Calculate advance — only AT_FINANCING fees reduce advance
        uint256 amountInWei = supplierBalance * 10**18;
        uint256 totalFeeAmount = totalAtFinancingFees + totalDeferredFees;
        if (totalAtFinancingFees >= amountInWei) revert IROR_ERC1155.TotalFeeExceedsBalance();

        uint256 financingId = tokenState[tokenId].nextFinancingId++;

        // Update supplier state (minimal)
        sState.hasFinanced = true;

        // Transfer ALL ROR tokens to financier
        _safeTransferFrom(msg.sender, financier, tokenId, supplierBalance, "");

        // Events carry all financing metadata
        emit IROR_ERC1155.RORFinanced(tokenId, financingId, msg.sender, financier, supplierBalance, sState.tier, totalFeeAmount);

        for (uint256 i = 0; i < fees.length; i++) {
            emit IROR_ERC1155.FeeItemAdded(tokenId, financingId, i + 1, fees[i].feeType, fees[i].amount, fees[i].recipient, fees[i].payer);
        }

        emit IROR_ERC1155.RORTransferred(tokenId, msg.sender, financier, supplierBalance);

        return financingId;
    }

    // ============ WTKN Release Functions ============

    function releaseWTKNToAllHoldersPaginated(
        uint256 tokenId,
        uint256 startIndex,
        uint256 batchSize
    ) public onlyRole(CRONJOB_ROLE) nonReentrant returns (uint256 successCount, uint256 totalAmount) {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();

        WTKNStake storage stake = wtknStakes[tokenId];
        if (stake.amount == 0) revert IROR_ERC1155.WTKNNotStaked();
        if (block.timestamp < stake.expiryDate) revert IROR_ERC1155.ExpiryDateNotReached();

        // Update status to MATURED on first release
        if (!stake.maturityReached) {
            stake.maturityReached = true;
            IROR_ERC1155.RoRStatus currentStatus = tokenState[tokenId].status;
            if (currentStatus != IROR_ERC1155.RoRStatus.MATURED &&
                currentStatus != IROR_ERC1155.RoRStatus.SETTLED &&
                currentStatus != IROR_ERC1155.RoRStatus.EXPIRED &&
                currentStatus != IROR_ERC1155.RoRStatus.DISPUTED) {
                _updateStatus(tokenId, IROR_ERC1155.RoRStatus.MATURED);
            }
        }

        address[] memory allHolders = _holders[tokenId];
        uint256 supply = totalSupply(tokenId);
        if (supply == 0) revert IROR_ERC1155.InvalidAmount();

        uint256 endIndex = batchSize == 0 ? allHolders.length : startIndex + batchSize;
        if (endIndex > allHolders.length) endIndex = allHolders.length;
        if (startIndex >= allHolders.length) return (0, 0);

        IWTKN wtknToken = IWTKN(stake.wtknContract);
        successCount = 0;
        totalAmount = 0;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address holder = allHolders[i];
            uint256 rorBalance = balanceOf(holder, tokenId);

            if (rorBalance == 0 || stake.releasedAmounts[holder] > 0) continue;

            uint256 wtknAmount = (stake.amount * rorBalance) / supply;

            if (wtknAmount == 0) {
                _hasClaimed[tokenId][holder] = true;
                emit IROR_ERC1155.WTKNReleased(tokenId, holder, 0);
                continue;
            }

            stake.releasedAmounts[holder] = wtknAmount;

            bool transferred = false;
            try wtknToken.transfer(holder, wtknAmount) returns (bool ok) {
                transferred = ok;
            } catch { }

            if (transferred) {
                stake.totalReleased += wtknAmount;
                emit IROR_ERC1155.WTKNReleased(tokenId, holder, wtknAmount);
                successCount++;
                totalAmount += wtknAmount;
            } else {
                // Keep releasedAmounts set so the main loop skips this holder on
                // future batches. Park the amount for an explicit retry call.
                _pendingWTKNRelease[tokenId][holder] = wtknAmount;
                emit IROR_ERC1155.WTKNReleaseRetryNeeded(tokenId, holder, wtknAmount);
            }
        }

        if (stake.totalReleased >= stake.amount && !stake.isReleased) {
            stake.isReleased = true;
            IWTKN(stake.wtknContract).recordUnstake(tokenId, stake.amount);
        }

        emit IROR_ERC1155.WTKNBatchReleased(tokenId, successCount, totalAmount);
        return (successCount, totalAmount);
    }

    /**
     * @notice Retry a WTKN release that previously failed (e.g. WTKN was paused
     *         or holder was blacklisted). Callable by CRONJOB_ROLE, ADMIN_ROLE,
     *         or the holder themselves once the blocking condition is resolved.
     */
    function retryWTKNRelease(uint256 tokenId, address holder)
        external
        nonReentrant
    {
        if (
            !hasRole(CRONJOB_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender) &&
            msg.sender != holder
        ) revert IROR_ERC1155.Unauthorized();

        uint256 pending = _pendingWTKNRelease[tokenId][holder];
        if (pending == 0) revert IROR_ERC1155.NoPendingRelease(tokenId, holder);

        WTKNStake storage stake = wtknStakes[tokenId];
        IWTKN wtknToken = IWTKN(stake.wtknContract);

        _pendingWTKNRelease[tokenId][holder] = 0;

        bool transferred = false;
        try wtknToken.transfer(holder, pending) returns (bool ok) {
            transferred = ok;
        } catch { }

        if (transferred) {
            stake.totalReleased += pending;
            if (stake.totalReleased >= stake.amount) stake.isReleased = true;
            emit IROR_ERC1155.WTKNReleased(tokenId, holder, pending);
        } else {
            // Still failing — put back in pending queue and re-emit for monitoring.
            _pendingWTKNRelease[tokenId][holder] = pending;
            emit IROR_ERC1155.WTKNReleaseRetryNeeded(tokenId, holder, pending);
        }
    }

    /**
     * @notice Admin escape hatch for a parked WTKN release that can never reach
     *         the original holder (e.g. the holder is permanently blacklisted on
     *         the WTKN contract). Pays the parked amount to an alternate
     *         recipient (e.g. treasury/escrow), clears the pending balance, and
     *         finalizes settlement so recordUnstake can run.
     * @dev    The transfer to newRecipient must succeed; if it reverts (e.g.
     *         newRecipient is also blacklisted) or returns false, the entire
     *         call reverts and no state is changed — pick a receivable address.
     * @param tokenId       The RoR token id.
     * @param holder        The original (stuck) holder whose release is parked.
     * @param newRecipient  Alternate address to receive the parked WTKN.
     */
    function redirectPendingRelease(
        uint256 tokenId,
        address holder,
        address newRecipient
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (newRecipient == address(0)) revert IROR_ERC1155.InvalidAddress();

        uint256 pending = _pendingWTKNRelease[tokenId][holder];
        if (pending == 0) revert IROR_ERC1155.NoPendingRelease(tokenId, holder);

        WTKNStake storage stake = wtknStakes[tokenId];

        // Effects before interaction. If the transfer below reverts, all of
        // these state changes roll back with it.
        _pendingWTKNRelease[tokenId][holder] = 0;
        _hasClaimed[tokenId][holder] = true;
        stake.totalReleased += pending;

        // Interaction — must succeed, otherwise revert the whole call.
        if (!IWTKN(stake.wtknContract).transfer(newRecipient, pending)) {
            revert IROR_ERC1155.WTKNTransferFailed();
        }

        emit IROR_ERC1155.WTKNReleaseRedirected(tokenId, holder, newRecipient, pending);
        emit IROR_ERC1155.WTKNReleased(tokenId, newRecipient, pending);

        // Finalize settlement if this was the last outstanding release.
        if (stake.totalReleased >= stake.amount && !stake.isReleased) {
            stake.isReleased = true;
            IWTKN(stake.wtknContract).recordUnstake(tokenId, stake.amount);
        }
    }

    // ============ Burn Functions ============

    function burnRORBatch(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) continue;

            uint256 balance = balanceOf(msg.sender, tokenId);
            if (balance == 0) continue;

            WTKNStake storage stake = wtknStakes[tokenId];

            // (A) Once the invoice due date has passed, the holder set is frozen
            // for settlement — mirror the transfer maturity gate and block
            // write-offs (burns) until this holder's WTKN has actually been
            // released. A burn in the post-due-date, pre-release window would
            // otherwise redistribute the buyer's collateral to the remaining
            // holders, or strand it entirely if it empties the supply.
            bool matured =
                (stake.expiryDate > 0 && block.timestamp >= stake.expiryDate) ||
                stake.maturityReached;
            if (matured && stake.releasedAmounts[msg.sender] == 0) continue;

            _burn(msg.sender, tokenId, balance);

            if (totalSupply(tokenId) == 0) {
                // (B) If the final receivable is written off while staked
                // collateral is still unreleased (only reachable before the due
                // date now that (A) blocks the post-due-date window), return the
                // unreleased WTKN to the anchor buyer instead of sealing it in
                // this contract forever.
                if (stake.amount > 0 && !stake.isReleased) {
                    uint256 remaining = stake.amount - stake.totalReleased;
                    if (remaining > 0) {
                        IWTKN wtkn = IWTKN(stake.wtknContract);
                        address buyer = wtkn.anchorBuyer();
                        stake.totalReleased = stake.amount;
                        stake.isReleased = true;
                        wtkn.recordUnstake(tokenId, remaining);
                        if (!wtkn.transfer(buyer, remaining)) {
                            revert IROR_ERC1155.WTKNTransferFailed();
                        }
                    }
                }
                _updateStatus(tokenId, IROR_ERC1155.RoRStatus.SETTLED);
                tokenState[tokenId].isSettled = true;
            }

            emit IROR_ERC1155.RORBurned(tokenId, msg.sender, balance);
        }
    }

    // ============ Fee Settlement Functions ============

    function settleFees(
        uint256 tokenId,
        uint256 financingId
    ) external onlyRole(CRONJOB_ROLE) nonReentrant {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();
        if (financingId == 0) revert IROR_ERC1155.FinancingNotFound();

        emit IROR_ERC1155.FeesSettled(tokenId, financingId, block.timestamp);
    }

    // ============ View Functions (inlined from RORViews) ============

    function getWTKNStake(uint256 tokenId)
        external view returns (
            address wtknContract, uint256 amount, uint256 expiryDate,
            bool isReleased, bool maturityReached, uint256 totalReleased
        )
    {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.TokenDoesNotExist();
        WTKNStake storage stake = wtknStakes[tokenId];
        return (stake.wtknContract, stake.amount, stake.expiryDate, stake.isReleased, stake.maturityReached, stake.totalReleased);
    }

    function getReleasedAmount(uint256 tokenId, address holder) external view returns (uint256) {
        return wtknStakes[tokenId].releasedAmounts[holder];
    }

    function getMaturityStatus(uint256 tokenId) external view returns (bool isMatured, uint256 timeRemaining) {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();
        WTKNStake storage stake = wtknStakes[tokenId];
        if (stake.expiryDate == 0) revert IROR_ERC1155.TokenDoesNotExist();
        isMatured = block.timestamp >= stake.expiryDate;
        timeRemaining = isMatured ? 0 : stake.expiryDate - block.timestamp;
    }

    function getHolders(uint256 tokenId)
        external view returns (address[] memory holders, uint256[] memory balances)
    {
        if (tokenId < MIN_TOKEN_ID || tokenId >= _tokenIdCounter) revert IROR_ERC1155.InvalidTokenId();
        address[] memory allHolders = _holders[tokenId];
        uint256 count = allHolders.length;
        holders = new address[](count);
        balances = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            holders[i] = allHolders[i];
            balances[i] = balanceOf(allHolders[i], tokenId);
        }
    }

    // ============ Hooks and Overrides ============

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        // Block transfers after maturity. This must run before balances change so
        // it reverts the whole transfer. Holder-set tracking is intentionally NOT
        // done here — it is handled in _afterTokenTransfer against final balances,
        // which stays correct for self-transfers (from == to) and batches with
        // duplicate token ids.
        for (uint256 i = 0; i < ids.length; i++) {
            if (from != address(0) && to != address(0)) {
                WTKNStake storage stake = wtknStakes[ids[i]];
                if (stake.expiryDate > 0 && block.timestamp >= stake.expiryDate) {
                    revert IROR_ERC1155.TransferAfterMaturity();
                }
            }
        }
    }

    /**
     * @dev Maintains the holder-tracking side-state (_holders / _isHolder /
     *      _holderIndexPlusOne) from each address's FINAL balance, after OZ has
     *      applied all balance updates. Deciding add/remove from the settled
     *      balance is correct for every transfer shape: full-balance
     *      self-transfers (from == to) keep the holder tracked because their
     *      final balance is still positive, and batches with duplicate token ids
     *      correctly remove the sender once the repeated entries deplete the
     *      balance to zero. _addHolder/_removeHolder are idempotent (guarded by
     *      _isHolder), so repeated ids in one batch are safe.
     */
    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._afterTokenTransfer(operator, from, to, ids, amounts, data);

        for (uint256 i = 0; i < ids.length; i++) {
            // Add recipient if they now hold a positive balance.
            if (to != address(0) && balanceOf(to, ids[i]) > 0) {
                _addHolder(ids[i], to);
            }
            // Remove sender only if their balance is now fully depleted.
            if (from != address(0) && balanceOf(from, ids[i]) == 0) {
                _removeHolder(ids[i], from);
            }
        }
    }

    function safeTransferFrom(
        address from, address to, uint256 id, uint256 amount, bytes memory data
    ) public override {
        super.safeTransferFrom(from, to, id, amount, data);
        emit IROR_ERC1155.RORTransferred(id, from, to, amount);
    }

    function safeBatchTransferFrom(
        address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data
    ) public override {
        super.safeBatchTransferFrom(from, to, ids, amounts, data);
        for (uint256 i = 0; i < ids.length; i++) {
            emit IROR_ERC1155.RORTransferred(ids[i], from, to, amounts[i]);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
