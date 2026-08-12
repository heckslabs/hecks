# Bug #71: Account.CloseAccount Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 350-359

## Problem

Account.CloseAccount command checks account/balance but no guard to enforce customer is not already closed. Should not close accounts for already-closed customers.

## Impact

- Attempting to close account for closed customer
- Account closure audit trail corrupted

## Fix

Add guard to enforce customer.status != "closed" before allowing close.
