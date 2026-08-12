# QA Session 2026-08-13 - Bug Hunt Progress

**Objective:** Find 10 bugs through systematic testing

## Bugs Found: 5 of 10

### Bug #71: SafeDepositBox.Rent Missing Reference ✅ FIXED
- **File:** examples/banking/bluebook/banking.bluebook (line 1201)
- **Issue:** Rent command missing `reference_to SafeDepositBox`
- **Impact:** Attempted to CREATE new box instead of UPDATE existing one
- **Fix Status:** COMMITTED in prior session

### Bug #72: Till.TakeIn Accepts Zero Amounts
- **File:** spec/fixtures/till.bluebook (line 51-64)
- **Issue:** TakeIn accepts Money (cents >= 0) but appends Mark VO (requires amount > 0)
- **Impact:** Crashes with Mark invariant violation when TakeIn called with zero
- **Type Mismatch:** Input type too permissive for output type
- **Fix:** Add predicate `given("taking must be positive") { amount.cents.positive? }`

### Bug #73: ATMCard.Retire Allows From Wrong State
- **File:** examples/banking/bluebook/banking.bluebook (line 538)
- **Issue:** `transition "Retire" => "retired", from: ["issued", "active"]`
- **Problem:** Semantically "retire" means deactivate, should only work from "active" state
- **Impact:** Can retire an unactivated card in "issued" state
- **Fix:** Change lifecycle to `from: "active"` only

### Bug #74: Pizzas.Order.Purchase Accepts Underpayment
- **File:** examples/pizzas/bluebook/pizzas.bluebook (Purchase command)
- **Issue:** No predicate validating payment >= pizza.price_cents
- **Evidence:** Pizza price 1200 cents, accepted payment of 1000 cents
- **Impact:** Revenue loss - customers can underpay
- **Fix:** Add predicate `given("payment covers price") { amount.cents >= pizza.price_cents.cents }`

### Bug #75: Pizzas.Order.CreatePizza Accepts Negative Prices
- **File:** examples/pizzas/bluebook/pizzas.bluebook (CreatePizza command)
- **Issue:** No predicate validating positive price
- **Evidence:** Pizza created successfully with price -1000 cents
- **Impact:** Business logic violation - could allow customers to be paid to order
- **Fix:** Add predicate `given("pizza price is positive") { pizza.price_cents.cents.positive? }`

## Remaining Search: 5 More Bugs Needed

### Testing Strategy Completed
- ✅ Banking domain - account operations, lifecycle transitions, overdraft prevention
- ✅ Pizzas domain - price validation, topping limits, lifecycle
- ✅ SafeDepositBox operations - rent/create distinction
- ✅ Customer lifecycle - state transitions, closure
- ✅ ATMCard operations - activation, retirement
- ✅ Edge cases - zero values, negative values, large numbers

### Testing Strategy In Progress
- [ ] Till domain edge cases (attempted, domain loading issue)
- [ ] Optional field handling
- [ ] Complex command sequences
- [ ] Cascade operations
- [ ] Query result validation
- [ ] Cross-domain interactions
- [ ] Transfer/Settlement operations
- [ ] Card payment operations
- [ ] Nested entity mutations

## Next Steps
Continue systematic edge case testing across remaining domains to find 5 additional functional bugs.
