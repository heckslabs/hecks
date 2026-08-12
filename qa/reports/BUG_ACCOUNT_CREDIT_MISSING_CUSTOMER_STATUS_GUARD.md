# Bug #69: Account.Credit Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 301-314

## Problem

Account.Credit command checks account status but no guard to enforce the customer is "active". Credits should not be deposited to suspended or closed customers' accounts.

## Impact

- Can credit suspended customers' accounts
- Can credit closed customers' accounts
- Suspended customer receives unauthorized deposits
- Credit audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing credit.
