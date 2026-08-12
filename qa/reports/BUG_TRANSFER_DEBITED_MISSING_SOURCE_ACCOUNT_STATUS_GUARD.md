# Bug #61: Transfer.Debited Missing Source Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 691-698

## Problem

Transfer.Debited command has a guard on transfer status but no guard to enforce the source account is "open". Money should only be debited from open accounts, not frozen or closed ones.

## Impact

- Can debit frozen source accounts
- Can debit closed source accounts
- Source account balance corrupted
- Settlement saga corrupted

## Fix

Add guard to enforce source.status == "open" before allowing debit.
