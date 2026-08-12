# Bug #16: ScheduledPayment.Abandon Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1052-1061

## Problem

ScheduledPayment.Abandon command has a guard on retry exhaustion but no guard to enforce status == "failed". The lifecycle declares `transition "Abandon" => "abandoned", from: "failed"` but the command lacks status guard.

## Impact

- Can abandon scheduled (not-yet-failed) payments
- Can abandon executed payments
- Can abandon cancelled payments
- Audit trail corrupted

## Fix

Add guard to enforce status == "failed" before allowing abandon.
