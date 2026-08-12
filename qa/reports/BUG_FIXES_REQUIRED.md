# Required Bug Fixes - Prioritized List

This document lists bugs identified in the 2026-08-13 QA session that require fixes.

## CRITICAL - Revenue Impact (2)

### Bug #74: Pizza Purchase Underpayment
**File:** `examples/pizzas/bluebook/pizzas.bluebook` (Purchase command)  
**Severity:** CRITICAL  
**Revenue Impact:** Direct loss - customers can underpay

```ruby
# FIX: Add to Purchase command
given("payment covers the price") { amount.cents >= pizza.price_cents.cents }
```

### Bug #75: Pizza Negative Price
**File:** `examples/pizzas/bluebook/pizzas.bluebook` (CreatePizza command)  
**Severity:** CRITICAL  
**Revenue Impact:** Potential arbitrage - customers could be paid to order

```ruby
# FIX: Add to CreatePizza command
given("pizza price is positive") { pizza.price_cents.cents.positive? }
```

## HIGH - Functionality Gaps (2)

### Bug #72: TakeIn Zero Amount Crash
**File:** `spec/fixtures/till.bluebook` (TakeIn command)  
**Severity:** HIGH  
**Impact:** Runtime crash instead of proper validation

```ruby
# FIX: Add to TakeIn command
given("taking must be a positive amount") { amount.cents.positive? }
```

### Bug #73: ATMCard Retire Wrong State
**File:** `examples/banking/bluebook/banking.bluebook` (line 538)  
**Severity:** HIGH  
**Impact:** Business logic violation

```ruby
# FIX: Change lifecycle from:
transition "Retire" => "retired", from: ["issued", "active"]

# To:
transition "Retire" => "retired", from: "active"
```

## REFERENCE (Fixed in Prior Session)

### Bug #71: SafeDepositBox.Rent Missing Reference ✅
**Status:** FIXED  
**Commit:** Earlier session  

---

## Implementation Order

1. **First:** Fix #74 and #75 (revenue impact, highest priority)
2. **Second:** Fix #72 (runtime crash prevention)
3. **Third:** Fix #73 (business logic correctness)

## Verification

After fixes, run:
```bash
# Create test file to verify each fix
ruby -r bundler/setup qa/verify_fixes.rb
```

Each bug fix should verify that:
- The invalid operation is now rejected with `GivenNotMet` error
- The error message is descriptive
- Valid operations still succeed

