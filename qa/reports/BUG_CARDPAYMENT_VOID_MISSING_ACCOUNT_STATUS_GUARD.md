# Bug #55: CardPayment.Void Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 811-815

## Problem

CardPayment.Void command has a guard on payment status but no guard to enforce the account is "open". Voids should only be processed for open accounts, not frozen or closed ones.

## Impact

- Can void payments from frozen accounts
- Can void payments from closed accounts
- Frozen account suddenly becomes active
- Void audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing void.
