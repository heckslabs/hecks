# Bug #32: Account.CorrectFee Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 376-383

## Problem

Account.CorrectFee command has a guard on fees but no guard to enforce it only corrects fees on "open" accounts. Should prevent fee correction on frozen or closed accounts.

## Impact

- Can correct fees on frozen accounts
- Can correct fees on closed accounts
- Frozen account suddenly becomes active
- Fee audit trail corrupted

## Fix

Add guard to enforce status == "open" before allowing fee correction.
