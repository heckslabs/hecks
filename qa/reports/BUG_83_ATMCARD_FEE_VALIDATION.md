# Bug #83: ATMCard.Issue Accepts Zero/Negative Daily Fee - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Business logic violation)  
**Type:** Missing Validation Predicate

---

## The Bug

ATMCard.Issue command accepts zero and negative daily_fee values, which violates business logic since fees should always be positive.

**Evidence:**
```ruby
# All of these are accepted (should fail)
daily_fee: { cents: 0, currency: 'USD' } ✓ (should fail)
daily_fee: { cents: -100, currency: 'USD' } ✓ (should fail)

# Valid values work
daily_fee: { cents: 100, currency: 'USD' } ✓
```

---

## Root Cause

ATMCard.Issue command has NO predicate validating that `daily_fee` is positive.

**Command Definition:**
```ruby
command "Issue" do
  reference_to Account
  attribute :serial,    CardSerial
  attribute :daily_fee, DailyFee
  then_set :serial,    to: :serial
  then_set :daily_fee, to: :daily_fee
  emits "ATMCardIssued"
end
```

No validation of `daily_fee > 0`.

---

## Business Impact

**CRITICAL** - Cards can be issued with zero or negative daily fees, creating:
- Accounting inconsistencies (negative fees = credits)
- Business logic violations (card fees should never be negative)
- Potential revenue impact

---

## Similar Pattern

This is part of a larger pattern of missing validation predicates:
- Bug #72: TakeIn zero amounts
- Bug #74: Purchase underpayment
- Bug #75: CreatePizza negative prices
- Bug #76: Withdraw status validation
- Bug #83: ATMCard daily_fee validation (NEW)

**Pattern:** Commands lack explicit business rule validation predicates.

---

## Fix Required

Add predicate to Issue command:
```ruby
given("daily fee is positive") { daily_fee.cents.positive? }
```

---

## Test Evidence

```
Test: Issue with zero daily_fee
Result: ✗ ACCEPTED (should reject)

Test: Issue with negative daily_fee
Result: ✗ ACCEPTED (should reject)

Test: Issue with positive daily_fee
Result: ✓ ACCEPTED (correct)
```
