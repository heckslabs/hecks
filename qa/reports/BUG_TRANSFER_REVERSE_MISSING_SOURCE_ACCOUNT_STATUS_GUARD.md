# Bug #64: Transfer.Reverse Missing Source Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 722-729

## Problem

Transfer.Reverse command has a guard on transfer status but no guard to enforce the source account is "open". Money should only be reversed back to open source accounts, not frozen or closed ones.

## Impact

- Can reverse to frozen source accounts
- Can reverse to closed source accounts
- Source account balance corrupted
- Transfer reversal audit trail corrupted

## Fix

Add guard to enforce source.status == "open" before allowing reversal.
