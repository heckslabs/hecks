# Bug: Transfer.Reverse Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 695-701

## Problem

Transfer.Reverse command has no guard to enforce it only reverses "debited" transfers. The lifecycle declares `transition "Reverse" => "reversed", from: "debited"` but the command lacks guards.

## Impact

- Can reverse transfers not yet debited
- Can reverse already-reversed transfers
- Source account reversal without prior debit
- Settlement saga corrupted

## Fix

Add guard to enforce status == "debited" before allowing reverse.
