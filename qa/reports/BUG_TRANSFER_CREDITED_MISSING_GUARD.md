# Bug: Transfer.Credited Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 687-693

## Problem

Transfer.Credited command has no guard to enforce it only credits "debited" transfers. The lifecycle declares `transition "Credited" => "credited", from: "debited"` but the command lacks guards.

## Impact

- Can credit already-credited transfers
- Can credit requested or settled transfers
- Destination account double-credited
- Settlement saga corrupted

## Fix

Add guard to enforce status == "debited" before allowing credit.
