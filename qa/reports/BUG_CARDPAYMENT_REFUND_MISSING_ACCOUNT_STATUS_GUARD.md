# Bug #50: CardPayment.Refund Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 814-817

## Problem

CardPayment.Refund command has a guard on payment status but no guard to enforce the account is "open". Refunds should only be processed for open accounts, not frozen or closed ones.

## Impact

- Can refund payments from frozen accounts
- Can refund payments from closed accounts
- Frozen account suddenly becomes active
- Refund audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing refund.
