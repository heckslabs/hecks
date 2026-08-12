# Bug #24: Account.Freeze Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 334-340

## Problem

Account.Freeze command has no guard to enforce it only freezes "open" accounts. The lifecycle declares `transition "Freeze" => "frozen", from: "open"` but the command lacks guards.

## Impact

- Can freeze already-frozen accounts
- Can freeze closed accounts
- Compliance audit trail corrupted
- Account state corrupted

## Fix

Add guard to enforce status == "open" before allowing freeze.
