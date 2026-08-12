# Bug #26: Account.CloseAccount Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 350-359

## Problem

Account.CloseAccount command has a guard on balance but no guard to enforce it only closes "open" or "frozen" accounts. The lifecycle declares `transition "CloseAccount" => "closed", from: ["open", "frozen"]` but the command lacks status guard.

## Impact

- Can close already-closed accounts
- Can close accounts in unknown state
- Account closure audit trail corrupted
- Double-closing attempt undetected

## Fix

Add guard to enforce status == "open" or status == "frozen" before allowing close.
