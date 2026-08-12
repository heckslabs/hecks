# Bug #31: Account.ApplyFee Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 366-374

## Problem

Account.ApplyFee command has a guard on balance but no guard to enforce it only applies fees to "open" accounts. Should prevent fee application to frozen or closed accounts.

## Impact

- Can apply fees to frozen accounts
- Can apply fees to closed accounts
- Frozen account suddenly becomes active
- Audit trail corrupted

## Fix

Add guard to enforce status == "open" before allowing fee application.
