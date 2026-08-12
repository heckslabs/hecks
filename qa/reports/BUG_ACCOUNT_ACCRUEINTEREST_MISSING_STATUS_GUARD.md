# Bug #33: Account.AccrueInterest Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 385-391

## Problem

Account.AccrueInterest command has NO guards at all. Should prevent interest accrual on frozen or closed accounts.

## Impact

- Can accrue interest on frozen accounts
- Can accrue interest on closed accounts
- Frozen account suddenly becomes active
- Interest audit trail corrupted

## Fix

Add guard to enforce status == "open" before allowing interest accrual.
