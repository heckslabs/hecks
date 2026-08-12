# Bug #59: ExternalTransfer.Recall Missing Status and Account Guards

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap + Cross-aggregate Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 955-958

## Problem

ExternalTransfer.Recall command has NO guards at all. It should:
1. Only recall transfers still in "sent" status
2. Only recall from open accounts

## Impact

- Can recall transfers not yet sent (in "requested" status)
- Can recall from frozen accounts
- Can recall from closed accounts
- External transfer saga corrupted

## Fix

Add guards to enforce status == "sent" and account.status == "open" before allowing recall.
