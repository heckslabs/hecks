# Bug #25: Account.Unfreeze Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 342-348

## Problem

Account.Unfreeze command has no guard to enforce it only unfreezes "frozen" accounts. The lifecycle declares `transition "Unfreeze" => "open", from: "frozen"` but the command lacks guards.

## Impact

- Can unfreeze already-open accounts
- Can unfreeze closed accounts
- Compliance audit trail corrupted
- Account state corrupted

## Fix

Add guard to enforce status == "frozen" before allowing unfreeze.
