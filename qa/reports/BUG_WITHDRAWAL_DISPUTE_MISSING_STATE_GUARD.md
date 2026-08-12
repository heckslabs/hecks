# Bug #35: Withdrawal.Dispute Missing State Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 531-539

## Problem

Withdrawal.Dispute command has no guard to enforce it only disputes "taken" withdrawals. The lifecycle declares `transition "Dispute" => "disputed", from: "taken"` but the command lacks guards.

## Impact

- Can dispute already-disputed withdrawals
- Dispute audit trail corrupted
- Double-dispute undetected
- Chargeback logic broken

## Fix

Add guard to enforce state == "taken" before allowing dispute.
