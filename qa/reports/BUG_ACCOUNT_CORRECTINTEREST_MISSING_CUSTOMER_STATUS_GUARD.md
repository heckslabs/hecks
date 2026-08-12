# Bug #68: Account.CorrectInterest Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 396-404

## Problem

Account.CorrectInterest command checks account status but no guard to enforce the customer is "active". Interest corrections should not be performed on suspended or closed customers' accounts.

## Impact

- Can correct interest on suspended customers' accounts
- Can correct interest on closed customers' accounts
- Suspended customer credited/debited without authorization
- Interest audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing interest correction.
