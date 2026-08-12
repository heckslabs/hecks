# Bug #78: Banking.Customer.Suspend CustomerStanding one_of Not Enforced

**Status:** IDENTIFIED

## The Bug

Suspend and Reinstate commands accept any standing value, ignoring the one_of constraint that should restrict standings.

**Evidence:**
```ruby
# All of these are accepted (should fail)
- standing: "bad" ✓ (should fail)
- standing: "frozen" ✓ (should fail)
- standing: "blocked" ✓ (should fail)
- standing: "premium" ✓ (should fail)
- standing: "invalid" ✓ (should fail)

# Valid standings work
- standing: "suspended" ✓
- standing: "good" ✓
```

## Root Cause

CustomerStanding VO has a one_of declaration but it's NOT being enforced, similar to Bug #77 (Size).

## File Location

examples/banking/bluebook/banking.bluebook (CustomerStanding VO definition and Suspend/Reinstate commands)

## Impact

HIGH - Customer standing can be set to invalid values, breaking business logic.

## Pattern

This is part of a larger pattern where one_of validation doesn't work for certain VOs:
- **Size:** one_of NOT enforced ✗
- **CustomerStanding:** one_of NOT enforced ✗
- **AccountKind:** one_of IS enforced ✓
- **StatementFrequency:** one_of IS enforced ✓

This suggests a framework-level bug where one_of validation is inconsistent or dependent on something specific about how the VO is defined (e.g., pattern validation interference).

