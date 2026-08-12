# Bug #28: LedgerEntry.Amend Missing State Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 245-258

## Problem

LedgerEntry.Amend command has a guard on amendment amount but no guard to enforce it only amends "posted" entries. The lifecycle declares `transition "Amend" => "posted", from: "posted"` but the command lacks state guard.

## Impact

- Can amend already-reversed entries
- Can amend amended entries repeatedly
- Ledger audit trail corrupted
- Amendment history lost

## Fix

Add guard to enforce state == "posted" before allowing amend.
