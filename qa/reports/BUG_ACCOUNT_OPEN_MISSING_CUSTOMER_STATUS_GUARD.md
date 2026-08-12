# Bug #44: Account.Open Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 284-298

## Problem

Account.Open command references a Customer but has no guard to enforce the customer is "active". Accounts should only be opened for active customers, not suspended or closed ones.

## Impact

- Can open accounts for suspended customers
- Can open accounts for closed customers
- Suspended customer gains transaction access
- Account audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing account opening.
