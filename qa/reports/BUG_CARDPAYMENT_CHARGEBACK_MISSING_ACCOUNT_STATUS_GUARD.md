# Bug #52: CardPayment.Chargeback Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 851-855

## Problem

CardPayment.Chargeback command has a guard on payment status but no guard to enforce the account is "open". Chargebacks should only be processed for open accounts, not frozen or closed ones.

## Impact

- Can process chargebacks on frozen accounts
- Can process chargebacks on closed accounts
- Frozen account suddenly becomes active
- Chargeback audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing chargeback processing.
