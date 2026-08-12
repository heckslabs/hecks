# Bug #65: Account.ApplyFee Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 366-374

## Problem

Account.ApplyFee command checks account status but no guard to enforce the customer is "active". Fee operations should not be performed on suspended or closed customers' accounts.

## Impact

- Can apply fees to suspended customers' accounts
- Can apply fees to closed customers' accounts
- Suspended customer charged without authorization
- Fee audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing fee application.
