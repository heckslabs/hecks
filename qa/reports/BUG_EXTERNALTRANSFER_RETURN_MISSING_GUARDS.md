# Bug #60: ExternalTransfer.Return Missing Status and Account Guards

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap + Cross-aggregate Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 960-963

## Problem

ExternalTransfer.Return command has NO guards at all. It should:
1. Only return transfers still in "sent" status
2. Only return from open accounts

## Impact

- Can return transfers not yet sent (in "requested" status)
- Can return from frozen accounts
- Can return from closed accounts
- External transfer saga corrupted

## Fix

Add guards to enforce status == "sent" and account.status == "open" before allowing return.
