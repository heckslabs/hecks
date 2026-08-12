# Bug #70: Account.Debit Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 316-335

## Problem

Account.Debit command checks account status but no guard to enforce the customer is "active". Debits should not be drawn from suspended or closed customers' accounts.

## Impact

- Can debit suspended customers' accounts
- Can debit closed customers' accounts
- Suspended customer loses money without authorization
- Debit audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing debit.
