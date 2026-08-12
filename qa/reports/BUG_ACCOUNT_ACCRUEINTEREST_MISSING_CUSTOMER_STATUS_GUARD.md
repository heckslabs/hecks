# Bug #67: Account.AccrueInterest Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 385-391

## Problem

Account.AccrueInterest command checks account status but no guard to enforce the customer is "active". Interest operations should not be performed on suspended or closed customers' accounts.

## Impact

- Can accrue interest on suspended customers' accounts
- Can accrue interest on closed customers' accounts
- Suspended customer credited without authorization
- Interest audit trail corrupted

## Fix

Add guard to enforce customer.status == "active" before allowing interest accrual.
