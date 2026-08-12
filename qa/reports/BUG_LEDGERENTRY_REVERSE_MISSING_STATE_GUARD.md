# Bug #27: LedgerEntry.Reverse Missing State Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 260-268

## Problem

LedgerEntry.Reverse command has no guard to enforce it only reverses "posted" entries. The lifecycle declares `transition "Reverse" => "reversed", from: "posted"` but the command lacks guards.

## Impact

- Can reverse already-reversed entries
- Can reverse amended entries
- Ledger audit trail corrupted
- Double-reversal undetected

## Fix

Add guard to enforce state == "posted" before allowing reverse.
