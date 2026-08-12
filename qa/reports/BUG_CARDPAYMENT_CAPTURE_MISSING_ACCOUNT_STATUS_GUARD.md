# Bug #49: CardPayment.Capture Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 802-806

## Problem

CardPayment.Capture command has a guard on payment status but no guard to enforce the account is "open". Payments should only be captured for open accounts, not frozen or closed ones.

## Impact

- Can capture payments from frozen accounts
- Can capture payments from closed accounts
- Frozen account suddenly becomes active
- Payment capture audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing capture.
