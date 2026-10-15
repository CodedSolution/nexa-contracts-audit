# Nexa Smart Contracts — Audit Package

This package contains the on-chain contracts for the Nexa deep supply-chain
financing protocol, prepared for external security audit.

Investors supply stable-value liquidity (**WLP**) into a per-buyer **SubPool** and
receive internal accounting units priced at NAV. The pool finances suppliers by
purchasing **ROR** (Record-of-Receivable, ERC-1155) invoice tokens at a discount;
at maturity the anchor buyer settles, and **WTKN** (a per-buyer wrapped token)
mediates buyer-side settlement flows.

---

## Audit scope

### In scope — audit targets

| Contract | File | Ver | Std | Pattern | Role |
|---|---|---|---|---|---|
| **SubPool** | `src/SubPool.sol` | 1.9.0 | — | UUPS · Ownable · Pausable · ReentrancyGuard · ERC1155Holder | Per-buyer investor liquidity pool: allocate/redeem, NAV oracle, supplier financing, settlement, fees, **investor allowlist** |
| **WLP** | `src/WLP.sol` | 1.1.0 | ERC-20 | UUPS · Ownable · Pausable | Working Liquidity Pool token; owner-minted, fiat-backed |
| **WTKN** | `src/WTKN.sol` | 2.0.0 | ERC-20 | UUPS · Ownable · Pausable | Per-anchor-buyer wrapped token with blacklist + transfer restrictions |
| **ROR (V2)** | `src/ROR_ERC1155_V2.sol` | 2.1.0 | ERC-1155 | UUPS · AccessControl | Multi-tier receivable/invoice tokens with maturity + settlement lifecycle |

### In scope — supporting files (dependencies of the above; not standalone)

| File | Purpose |
|---|---|
| `src/ROR_ERC1155_Storage.sol` | Abstract storage/base for `ROR_ERC1155_V2` (state, roles, UUPS, storage `__gap`) |
| `src/interfaces/IROR_ERC1155.sol` | ROR interface used by the storage/base contract |
| `src/libraries/RORPermissions.sol` | Role identifiers shared across ROR (`ADMIN_ROLE`, `MINTER_ROLE`, `UPGRADER_ROLE`, `CRONJOB_ROLE`) |

### Out of scope
- **ROR V1** (`ROR_ERC1155.sol`) — superseded by V2; excluded at the client's request.
- All off-chain code (web2/web3 backends, frontends). These interact with the
  contracts but are not part of this on-chain audit.
- OpenZeppelin library code (audited upstream) — see versions below.

---

## Architecture & cross-contract flows

```
Investor --WLP--> SubPool          (allocate: WLP in, units out @ NAV)
SubPool  --WLP--> Supplier         (financeSupplier: discounted WLP vs ROR faceValue)
SubPool  holds    ROR (ERC-1155)   (receivable financed)
Anchor buyer -> settlement -> SubPool (receiveSettlement in WLP; WTKN mediates buyer side)
SubPool  --WLP--> Investor          (redeem: units back to WLP @ NAV, optional early-exit penalty)
```

Reviewers should assess the **interactions**, not just each contract in isolation:
- SubPool ↔ ROR (financing against ERC-1155 face value; utilisation cap; default handling)
- SubPool ↔ WLP (liquidity accounting: `totalWlpBalance` vs actual balance; NAV math)
- WTKN transfer restrictions (transfers allowed only to the anchor buyer or
  authorized ROR contracts) and their effect on settlement.

---

## Business logic & economic model

### The lifecycle in one pass
1. **Origination.** An anchor buyer stakes **WTKN** equal to a supplier invoice and
   mints an **ROR** token (the on-chain receivable) with a due date.
2. **Financing.** A **SubPool** buys that receivable by paying the supplier a
   **discounted** amount of **WLP** now, and books the full invoice face value as
   expected at maturity. The discount is the pool's gross yield.
3. **Yield accrual.** As financings earn and interest income arrives, pool value
   rises → **NAV per unit** rises → every investor gains proportionally.
4. **Settlement.** At maturity the anchor buyer repays in WLP; the pool records
   settlement, the staked WTKN is released, and the ROR is burned.
5. **Redemption.** Investors redeem their units back to WLP at the prevailing NAV.

### SubPool — investor economics
- **Allocation.** An investor deposits WLP and receives internal **Units** priced at
  the current NAV: `units = wlpAmount · 1e18 / currentNav`. NAV starts at `1.0`.
  Units are the ownership share; their WLP value floats with NAV.
- **Two products:**
  - **Participatory** (type 0): open-ended; uses pool-level lock-up and minimum.
  - **Series** (type 1): fixed tranches, each with its own lock-up, subscription
    window (start/end), max size, and minimum allocation. A Series has a **Net
    Investor Rate** (`seriesNirBps`, its *maximum* return, set once when its
    window opens — this freezes its terms) and a single issue NAV (`seriesEntryNav`,
    NAV₀), set once by the owner with `setSeriesEntryNav` before the first
    allocation: the last NAV published before the Series' start date. Allocations
    revert until it is set, and are only accepted for `SERIES_ALLOCATION_WINDOW`
    (7 days) from the start date, never at or after `endDate`. Instalment
    redemptions are priced as the difference of cumulative floors, so instalments
    sum to exactly what a single full redemption would pay. Its **Maximum Redemption Price** is
    `MRP = floor4(NAV₀ · (1 + NIR · (endDate − startDate) / 365 days))`.
    There is **no Reserve Fund and no top-up** (v1.9.0): at maturity the owner
    fixes `seriesMaturityNav` (only after that day's NAV push) and redeems each
    allocation with `redeemSeries` at **`min(MRP, NAV_m)`**, in full or in
    instalments. Above the MRP the surplus stays in the pool (Participatory
    holders); below it the Series investor bears the shortfall. Investors cannot
    call `redeem`/`redeemEarly` on a Series allocation.
- **NAV appreciation = yield.** The backend pushes NAV daily (oracle). Financing
  profit and injected interest income (`receiveInterest`) raise pool value without
  minting new units, so NAV rises and existing holders capture the return.
- **Precision (v1.9.0).** NAV is exactly 4 dp (`updateNav` rejects anything else);
  units issued and every WLP payout are rounded **down** to whole cents (2 dp), the
  remainder staying in the pool; amounts passed in (allocation, partial redeem
  units, financing, settlement, interest) must already be whole cents.
- **Lock-up & redemption.** Each allocation is locked until its `lockUpEndsAt`.
  `redeem()` returns `units · currentNav / 1e18` in WLP (Participatory only). `redeemEarly()` (before the
  lock-up) applies `earlyExitPenaltyBps`; the penalty **stays in the pool**, so it
  accretes to the remaining investors via NAV.
- **Capacity.** `maxPoolSize` caps total WLP the pool will accept.
- **Investor allowlist** (this release). When `whitelistEnabled`, only owner-approved
  addresses can allocate; the backend auto-approves vetted investors at allocation.

### SubPool — financing economics & risk
- **Discount = return.** `financeSupplier` sends the supplier a discounted WLP amount
  now against an ROR whose `faceValue` is expected at maturity. Face − deployed is
  the pool's earning.
- **Utilisation cap.** `maxUtilisationBps` limits the share of pool value deployed
  into financings, preserving a liquidity buffer for redemptions.
- **Settlement.** `receiveSettlement` reduces outstanding by face value and credits
  the repaid WLP to the pool balance.
- **Default / credit risk.** `recordDefault` writes off bad debt; the loss reduces
  outstanding and is absorbed as a **NAV drop** — i.e. investors bear the credit
  risk of the receivables, pro-rata.
- **Fees.** `collectPlatformFee` transfers WLP to the platform/trustee fee wallet.
  The Reserve Fund was removed in v1.9.0: `financeSupplier` reverts on a non-zero
  `reserveFee` (the parameter stays for ABI compatibility), new pools pass a zero
  reserve wallet, and fees earmarked before the upgrade are returned to the
  pool's capital with `releaseReserveFeeToPool` (`collectReserveFund` remains,
  but the platform no longer uses it).

### WLP — the unit of account
Stable-value ERC-20 (≈ 1:1 to fiat, e.g. RM), owner-minted against off-chain
`fiatReserves`. It is the settlement/pricing currency for allocation, financing,
settlement, and fees across the protocol.

### WTKN — buyer settlement instrument
Per-anchor-buyer wrapped ERC-20. The buyer **stakes WTKN to originate an ROR**
(collateralising the receivable) and receives it back on settlement. Transfers are
**restricted** to the anchor buyer or authorised ROR contracts, plus a compliance
**blacklist** — so WTKN cannot circulate freely and is confined to settlement flows.

### ROR V2 — the receivable, multi-tier
ERC-1155 invoice token minted against staked WTKN with a `dueDate`. From **2.1.0**
one ROR unit is one **sen** (RM0.01, `1e16` wei of WTKN): an invoice of RM35,000.45
stakes 35,000.45 WTKN and mints 3,500,045 units. `mintROR` rejects an amount that is
not a whole number of sen (`InvoiceAmountNotWholeSen`) or below one sen
(`InvoiceAmountTooSmall`). Tokens minted by an earlier implementation keep one unit
= RM1 (`1e18` wei); `weiPerUnit(tokenId)` returns each token's scale. Models a
**deep supply chain**: the originating supplier holds **tier 1**, and each onward
transfer down the chain assigns **tier + 1** (forward-only — backwards and
cross-tier-skip transfers are rejected). Transfers are blocked at/after maturity. On
settlement the staked WTKN is released to holders (`getReleasedAmount`) and the ROR
is burned (`burnRORBatch`).

---

## Roles & trust assumptions

- **SubPool** — single `owner` (pool wallet EOA, backend-operated). Owner controls
  NAV updates (oracle push), supplier financing, settlement recording, defaults,
  fees, config setters, the investor allowlist, pause, and UUPS upgrade.
  `allocate()`/`redeem()` are public; `allocate()` is gated by the allowlist **only
  when `whitelistEnabled == true`** (default `false`).
- **WLP / WTKN** — `owner` controls mint/burn, pause, and upgrade. WTKN additionally
  maintains a `blacklisted` mapping and restricts transfer recipients.
- **ROR V2** — OpenZeppelin `AccessControl` roles (`ADMIN_ROLE`, `MINTER_ROLE`,
  `UPGRADER_ROLE`, `CRONJOB_ROLE`). Minting is `MINTER_ROLE`; upgrades `UPGRADER_ROLE`.

The protocol is **operator-trusted**: NAV is an off-chain oracle push, and the
investor allowlist mirrors an off-chain KYC/vetting decision rather than acting as
an independent on-chain gate. Centralization risk should be assessed accordingly.

---

## Upgradeability & storage layout ⚠️

**All four contracts are UUPS upgradeable** (`_authorizeUpgrade` gated by owner /
`UPGRADER_ROLE`). The single highest-value review area is **storage-layout safety
across upgrades**:

- **SubPool v1.2.0 → v1.3.0** (this release): the investor allowlist state
  (`isWhitelisted`, `whitelistEnabled`) is **appended after all prior state**, plus a
  trailing `uint256[50] __gap`. Please verify the layout is strictly append-only vs.
  the currently-deployed v1.2.0 (no reordering/insertion) so live pools upgrade
  without storage corruption.
- **SubPool → v1.9.0** (this release): appends `seriesNirBps`, `seriesEntryNav`
  and `seriesMaturityNav` (top-level mappings, slots 479–481) after
  `unitsRedeemedOf`, shrinking `__gap` 45 → 42; the `Allocation` and `Series`
  structs are unchanged. `migrateV5` (`reinitializer(5)`) is emit-only; Series
  allocated before the upgrade are back-filled once via `adminSetSeriesLegacyTerms`.
- **ROR V2 → 2.1.0** (this release): appends `weiPerUnit` as the **last member of
  the `TokenState` struct**, which is only ever stored as the value of the
  `tokenState` mapping (never in an array, never copied whole). The new member takes
  the struct's third slot, which no earlier implementation wrote, so it reads `0`
  for tokens minted before the upgrade; `_weiPerUnit` maps `0` to the legacy `1e18`.
  Top-level layout and `__gap` are unchanged by 2.1.0. Compared with the ROR in the
  previous audit package, this source also carries the earlier fixes already on the
  development branch: the `feesSettled` idempotency mapping appended after
  `wtknStakes` (`__gap` 42 → 41), the checked `wtknToken.transferFrom` in `mintROR`,
  and paginated release reading `_holders` from storage rather than copying it. Please verify this claim, and
  that every units↔wei conversion uses the token's own scale. The only such
  conversion is the at-financing fee cap in `financeMyRORBalance`; WTKN release at
  maturity is pro-rata on `stake.amount` and so does not depend on the scale.
- **ROR V2 → 2.1.0, unstake accounting:** every path that finishes a stake
  (paginated release, `retryWTKNRelease`, `redirectPendingRelease`, `burnRORBatch`)
  now goes through `_finalizeStakeRelease`, which records the **whole** stake as
  unstaked on WTKN exactly once. Previously some paths recorded only the remainder
  or nothing, leaving `WTKN.totalStaked` inflated. Please check this cannot double
  count for a token part-way through settlement when its proxy is upgraded, and
  whether `WTKN.recordUnstake` can revert and so block settlement.
- Confirm each contract's initializer cannot be re-invoked and that
  `_disableInitializers()` is set in constructors.

---

## Build / compile

Toolchain (from the source repo's `foundry.toml`):

- **Foundry** (forge), **solc `0.8.24`**, pragma `^0.8.20`
- Optimizer **on**, `optimizer_runs = 1`, **`via_ir = true`** (required — the code
  hits "stack too deep" without IR)

Dependencies (install into `lib/` or map via remappings):

| Package | Version |
|---|---|
| `openzeppelin-contracts` (non-upgradeable; interfaces/SafeERC20) | **v5.5.0** |
| `openzeppelin-contracts-upgradeable` | **v4.9.6** |

> Note the intentional version split: upgradeable base classes come from OZ **4.9.6**
> (e.g. `__Ownable_init()` with no args), while stable interfaces (`IERC20`,
> `SafeERC20`, `IERC1155`) come from OZ **5.5.0**. Reviewers should confirm this mix
> compiles and introduces no ABI/behavioral mismatch.

Remappings:
```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

Example `foundry.toml` profile:
```toml
[profile.default]
src = "src"
solc = "0.8.24"
optimizer = true
optimizer_runs = 1
via_ir = true
```

---

## Directory layout

```
nexa_contracts_audit/
├── README.md
└── src/
    ├── SubPool.sol                 # audit target (1703 LOC)
    ├── WLP.sol                     # audit target (223 LOC)
    ├── WTKN.sol                    # audit target (372 LOC)
    ├── ROR_ERC1155_V2.sol          # audit target (675 LOC)
    ├── ROR_ERC1155_Storage.sol     # dependency (165 LOC)
    ├── interfaces/
    │   ├── IROR_ERC1155.sol        # dependency (248 LOC)
    │   └── ISubPool.sol            # SubPool interface, generated from its ABI (340 LOC)
    └── libraries/
        └── RORPermissions.sol      # dependency (24 LOC)
```

Total in-scope: **~3,400 LOC** across 7 files (4 targets + 3 dependencies), plus `ISubPool.sol`.

---

## Suggested focus areas
1. **Storage-layout compatibility** on the SubPool upgrades (see above), incl. v1.9.0,
   and on ROR 2.1.0 (the `TokenState.weiPerUnit` append).
2. **ROR sen units (2.1.0)** — whole-sen mint checks, the per-token scale
   (`weiPerUnit`, legacy `0` → `1e18`), the at-financing fee cap at both scales,
   rounding of the pro-rata WTKN release with sen units (including after a burn
   before maturity), and the single `recordUnstake` per stake.
3. **Series redemption at min(MRP, NAV_m)** — MRP math and rounding, the one-time
   NAV_m fix (stale-NAV guard), instalment (`redeemSeries` partial) accounting,
   the legacy back-fill, and that no path pays a Series more than min(MRP, NAV_m).
4. **NAV & unit accounting** — allocate/redeem math, rounding, early-exit penalty,
   `totalWlpBalance` vs actual token balance drift.
5. **Financing & settlement** — utilisation cap, default write-offs, ROR faceValue
   vs deployed WLP, re-entrancy on external token calls (CEI ordering).
6. **Access control & upgrade authorization** across all four contracts.
7. **WTKN transfer restrictions & blacklist** — can they wedge settlement or trap funds?
8. **Investor allowlist** — the on-chain gate vs. the off-chain (operator) trust model.
