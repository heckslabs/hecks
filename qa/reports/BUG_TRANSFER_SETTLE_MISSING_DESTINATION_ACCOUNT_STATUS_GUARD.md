# Bug #57: Transfer.Settle Missing Destination Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 700-707

## Problem

Transfer.Settle command has a guard on transfer status but no guard to enforce the destination account is "open". Settlement should only be recorded for open destination accounts, not frozen or closed ones.

## Impact

- Can settle transfers to frozen accounts
- Can settle transfers to closed accounts
- Settlement saga corrupted
- Destination account balance undefined

## Fix

Add guard to enforce destination.status == "open" before allowing settlement.
