# Bug #37: Transfer.Request Missing Source Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 660-679

## Problem

Transfer.Request command references source and destination accounts but has no guard to enforce the source account is "open". Transfers should not be initiated from frozen or closed accounts.

## Impact

- Can initiate transfers from frozen accounts
- Can initiate transfers from closed accounts
- Frozen account suddenly becomes active
- Compliance controls bypassed

## Fix

Add guard to enforce source.status == "open" before allowing transfer request.
