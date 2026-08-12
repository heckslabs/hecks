# Bug #36: CardPayment.Authorize Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 784-794

## Problem

CardPayment.Authorize command references an Account but has no guard to enforce the account is "open". Card payments should not be authorized on frozen or closed accounts.

## Impact

- Can authorize charges on frozen accounts
- Can authorize charges on closed accounts
- Frozen account suddenly becomes active
- Compliance controls bypassed

## Fix

Add guard to enforce account status == "open" before allowing authorization.
