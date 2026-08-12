# Bug #15: ScheduledPayment.Retry Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1036-1049

## Problem

ScheduledPayment.Retry command has a guard on retry count but no guard to enforce status == "failed". The lifecycle declares `transition "Retry" => "failed", from: "failed"` but the command lacks status guard.

## Impact

- Can retry scheduled (not-yet-executed) payments
- Can retry executed payments
- Can retry cancelled or abandoned payments
- Retry logic corrupted

## Fix

Add guard to enforce status == "failed" before allowing retry.
