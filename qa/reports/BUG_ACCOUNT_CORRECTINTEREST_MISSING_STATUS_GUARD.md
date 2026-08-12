# Bug #34: Account.CorrectInterest Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 393-399

## Problem

Account.CorrectInterest command has guards on balance and interest but no guard to enforce it only corrects interest on "open" accounts. Should prevent correction on frozen or closed accounts.

## Impact

- Can correct interest on frozen accounts
- Can correct interest on closed accounts
- Frozen account suddenly becomes active
- Interest audit trail corrupted

## Fix

Add guard to enforce status == "open" before allowing interest correction.
