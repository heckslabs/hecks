# Bug #56: Transfer.Credited Missing Destination Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 709-716

## Problem

Transfer.Credited command has a guard on transfer status but no guard to enforce the destination account is "open". Credits should only be recorded for open destination accounts, not frozen or closed ones.

## Impact

- Can credit frozen destination accounts
- Can credit closed destination accounts
- Destination account balance corrupted
- Settlement saga corrupted

## Fix

Add guard to enforce destination.status == "open" before allowing credit.
