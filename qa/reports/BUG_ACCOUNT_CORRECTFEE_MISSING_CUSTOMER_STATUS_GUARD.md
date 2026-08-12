# Bug #66: Account.CorrectFee Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 376-383

## Problem

Account.CorrectFee command checks account status but no guard to enforce the customer is "active". Fee corrections should not be performed on suspended or closed customers' accounts.

## Impact

- Can correct fees on suspended customers' accounts
- Can correct fees on closed customers' accounts
- Suspended customer charged/credited without authorization
- Fee audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing fee correction.
