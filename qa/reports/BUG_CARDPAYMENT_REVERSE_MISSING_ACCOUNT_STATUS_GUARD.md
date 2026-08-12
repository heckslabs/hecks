# Bug #51: CardPayment.Reverse Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 819-823

## Problem

CardPayment.Reverse command has a guard on payment status but no guard to enforce the account is "open". Reversals should only be processed for open accounts, not frozen or closed ones.

## Impact

- Can reverse payments from frozen accounts
- Can reverse payments from closed accounts
- Frozen account suddenly becomes active
- Reversal audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing reversal.
