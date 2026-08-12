# Bug #48: ATMCard.Issue Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 555-567

## Problem

ATMCard.Issue command references an Account but has no guard to enforce the account is "open". Cards should only be issued for open accounts, not frozen or closed ones.

## Impact

- Can issue cards for frozen accounts
- Can issue cards for closed accounts
- Frozen account suddenly becomes active
- Card issuance audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing card issuance.
