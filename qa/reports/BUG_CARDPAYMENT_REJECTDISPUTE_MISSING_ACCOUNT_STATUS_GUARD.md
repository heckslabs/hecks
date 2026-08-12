# Bug #53: CardPayment.RejectDispute Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 857-861

## Problem

CardPayment.RejectDispute command has a guard on payment status but no guard to enforce the account is "open". Dispute rejections should only be processed for open accounts, not frozen or closed ones.

## Impact

- Can reject disputes on frozen accounts
- Can reject disputes on closed accounts
- Frozen account suddenly becomes active
- Dispute resolution audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing dispute rejection.
