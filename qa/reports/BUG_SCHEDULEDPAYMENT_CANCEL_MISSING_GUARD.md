# Bug #13: ScheduledPayment.Cancel Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1005-1008

## Problem

ScheduledPayment.Cancel command has no guard to enforce it only cancels "scheduled" payments. The lifecycle declares `transition "Cancel" => "cancelled", from: "scheduled"` but the command lacks guards.

## Impact

- Can cancel already-executed payments
- Can cancel already-failed payments
- Can cancel already-abandoned payments
- Audit trail inconsistent

## Fix

Add guard to enforce status == "scheduled" before allowing cancel.
