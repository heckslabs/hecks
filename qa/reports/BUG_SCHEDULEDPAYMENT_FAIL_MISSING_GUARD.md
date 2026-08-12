# Bug #14: ScheduledPayment.Fail Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1010-1016

## Problem

ScheduledPayment.Fail command has no guard to enforce it only fails "scheduled" payments. The lifecycle declares `transition "Fail" => "failed", from: "scheduled"` but the command lacks guards.

## Impact

- Can mark already-executed payments as failed
- Can mark already-cancelled payments as failed
- Can mark already-failed payments as failed again
- Retry saga corrupted

## Fix

Add guard to enforce status == "scheduled" before allowing fail.
