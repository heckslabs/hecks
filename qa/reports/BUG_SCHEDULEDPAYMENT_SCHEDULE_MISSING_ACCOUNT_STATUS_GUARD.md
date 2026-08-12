# Bug #39: ScheduledPayment.Schedule Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1006-1016

## Problem

ScheduledPayment.Schedule command references an Account but has no guard to enforce the account is "open". Scheduled payments should not be scheduled on frozen or closed accounts.

## Impact

- Can schedule payments on frozen accounts
- Can schedule payments on closed accounts
- Frozen account suddenly becomes active
- Scheduled payment audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing payment scheduling.
