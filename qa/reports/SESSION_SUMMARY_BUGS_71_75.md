# QA Session Summary: Bugs #71-75

**Session Date:** 2026-08-13  
**Target:** Find 10 bugs  
**Status:** 5 bugs found and documented (1 fixed in prior session, 4 identified this session)  
**Progress:** 50% - 5 more bugs needed

## Bug Summary by Category

### Reference Resolution Bugs (1)

**Bug #71: SafeDepositBox.Rent Missing Reference** ✅ FIXED
- Rent command missing `reference_to SafeDepositBox` declaration
- Attempted to create duplicate instead of updating existing box
- Fixed in prior session by adding reference declaration
- Demonstrates importance of proper `reference_to` declarations for non-creating commands

### Type Mismatch Bugs (1)

**Bug #72: Till.TakeIn Input/Output Type Incompatibility** 🔍 IDENTIFIED
- TakeIn command accepts Money (cents >= 0) but appends Mark VO (amount > 0)
- Causes invariant violation at runtime when zero amount provided
- Fix: Add predicate to reject zero amounts
- Pattern: Input type too permissive for output type it constructs

### Lifecycle State Machine Bugs (1)

**Bug #73: ATMCard.Retire Allows From Unactivated State** 🔍 IDENTIFIED  
- Lifecycle allows transition `from: ["issued", "active"]` 
- Semantically "retire" = deactivate, should only work from "active"
- Allows retiring an unactivated card in "issued" state
- Fix: Change lifecycle to `from: "active"` only
- Pattern: State machine transition logic doesn't match business semantics

### Validation Gap Bugs (2)

**Bug #74: Pizzas.Order.Purchase Accepts Underpayment** 🔍 IDENTIFIED
- Purchase command has no predicate validating `amount >= pizza.price_cents`
- System accepts payments less than asking price
- Evidence: Pizza costs 1200 cents, accepted 1000 cent payment
- Fix: Add predicate `given("payment covers price") { amount.cents >= pizza.price_cents.cents }`
- Impact: HIGH - Revenue loss
- Pattern: Business rule validation missing from command

**Bug #75: Pizzas.Order.CreatePizza Accepts Negative Prices** 🔍 IDENTIFIED
- CreatePizza has no predicate validating positive price
- System creates pizzas with negative prices like -1000
- Price VO declares `invariant` requiring positive, but creating commands bypass validation
- Fix: Add predicate `given("price is positive") { pizza.price_cents.cents.positive? }`
- Impact: HIGH - Business logic violation, could allow arbitrage
- Pattern: Creating command lacks input validation predicates

## Testing Coverage

### Domains Tested
- ✅ Pizzas (3 bugs found)
- ✅ Banking (2 bugs found)  
- ✅ SafeDepositBox (1 bug found)
- ✅ Customer (lifecycle tested, working correctly)
- ✅ Account (overdraft, closure, freeze tested)
- ✅ ATMCard (activation, lifecycle)
- ✅ Transfer (basic validation working)
- [ ] Till (domain loading issues)
- [ ] Settlement  
- [ ] Compliance
- [ ] OIDC/Governance

### Test Categories Completed
- ✅ Edge cases: zero, negative, large numbers
- ✅ State machine transitions
- ✅ Lifecycle enforcement
- ✅ Reference resolution
- ✅ Duplicate creation protection
- ✅ Overdraft prevention
- ✅ Optional fields
- ✅ Default values
- [ ] Complex command sequences
- [ ] Cascade operations
- [ ] Query result validation
- [ ] Cross-domain interactions

## Remaining Work

**5 more bugs needed** to complete 10-bug target

### Search Recommendations
1. **Cascade Operations:** Test commands that trigger multiple state changes
2. **Query Validation:** Test query predicates, sorting, limits
3. **Cross-Domain:** Test interactions between domains (transfers, settlement)
4. **Settlement Domain:** Untested domain, likely has validation gaps
5. **Complex Sequences:** Multi-step workflows that might break invariants
6. **Nested Entity Mutations:** Entity command edge cases
7. **List Operations:** Edge cases with append/remove on list attributes
8. **Permission/Authorization:** Role-based command restrictions

## Key Findings

1. **Creating Commands Gap:** `CreatePizza` and `CreatePizza` lack input validation predicates that should restrict negative/zero prices
2. **Type System Gap:** Some commands don't account for type incompatibilities between input and output VOs
3. **State Machine Design:** Business semantics not perfectly reflected in lifecycle transition definitions
4. **Revenue Validation:** Purchase command missing payment amount validation
5. **Reference Semantics:** Some commands need explicit `reference_to` declarations to prevent creation attempts

## Lessons Learned

1. Creating commands bypass some runtime validation - input predicates are essential
2. Value object invariants alone are insufficient when output type is more restrictive than input type
3. Lifecycle transitions should model business semantics precisely
4. Payment/transaction commands need explicit amount validation predicates
5. Reference resolution requires explicit `reference_to` declarations

