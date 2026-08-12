# Bug #40: ATMCard.Withdraw Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 579-590

## Problem

ATMCard.Withdraw command references an ATMCard which holds an Account, but has no guard to enforce the account is "open". Cash withdrawals should not be allowed from frozen or closed accounts.

## Impact

- Can withdraw cash from frozen accounts
- Can withdraw cash from closed accounts
- Frozen account suddenly becomes active
- Account balance audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing cash withdrawal.
