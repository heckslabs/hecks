# Bug #43: SafeDepositBox.Rent Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1239-1251

## Problem

SafeDepositBox.Rent command references a Customer but has no guard to enforce the customer is "active". Safe deposit boxes should only be rented to active customers, not suspended or closed ones.

## Impact

- Can rent boxes to suspended customers
- Can rent boxes to closed customers
- Suspended customer gains vault access
- Vault audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing box rental.
