# Bug #12: ScheduledPayment.Execute Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1000-1003

## Problem

ScheduledPayment.Execute command has no guard to enforce it only executes "scheduled" payments. The lifecycle declares `transition "Execute" => "executed", from: "scheduled"` but the command lacks guards.

## Impact

- Can execute already-executed payments
- Can execute cancelled or abandoned payments
- Double payment to recipient
- Account balance corrupted

## Fix

Add guard to enforce status == "scheduled" before allowing execute.
