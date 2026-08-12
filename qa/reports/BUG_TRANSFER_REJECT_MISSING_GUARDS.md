# Bug #54: Transfer.Reject Missing Status and Account Guards

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap + Cross-aggregate Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 727-733

## Problem

Transfer.Reject command has no guards at all. It should:
1. Only reject transfers still in "requested" status (before money moved)
2. Only reject transfers from open accounts

## Impact

- Can reject already-debited transfers (money already moved from source)
- Can reject transfers from frozen accounts
- Can reject transfers from closed accounts
- Transfer settlement saga corrupted

## Fix

Add guards to enforce status == "requested" and source.status == "open" before allowing rejection.
