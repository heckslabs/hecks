# Bug: Transfer.Debited Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 671-677

## Problem

Transfer.Debited command has no guard to enforce it only debits "requested" transfers. The lifecycle declares `transition "Debited" => "debited", from: "requested"` but the command lacks guards.

## Impact

- Can debit already-debited transfers
- Can debit credited or settled transfers
- Source account double-debited
- Settlement saga corrupted

## Fix

Add guard to enforce status == "requested" before allowing debit.
