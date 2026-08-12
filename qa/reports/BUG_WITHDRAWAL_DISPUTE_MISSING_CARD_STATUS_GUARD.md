# Bug #63: Withdrawal.Dispute Missing Card Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 531-544

## Problem

Withdrawal.Dispute command has a guard on withdrawal state but no guard to enforce the card is not "retired". Disputes should only be filed for withdrawals on active cards, not retired ones.

## Impact

- Can dispute withdrawals on retired cards
- Chargeback dispute trail corrupted
- Retired card suddenly becomes relevant

## Fix

Add guard to enforce card status != "retired" before allowing dispute.
