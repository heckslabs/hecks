# Bug: Transfer.Settle Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 679-685

## Problem

Transfer.Settle command has no guard to enforce it only settles "credited" transfers. The lifecycle declares `transition "Settle" => "settled", from: "credited"` but the command lacks guards.

## Impact

- Can settle already-settled transfers
- Can settle transfers not yet credited
- Settlement saga broken
- Audit trail corrupted

## Fix

Add guard to enforce status == "credited" before allowing settle.
