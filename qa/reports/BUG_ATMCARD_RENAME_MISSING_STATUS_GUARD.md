# Bug #46: ATMCard.Rename Missing Status Guard

**Severity:** MEDIUM  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 569-578

## Problem

ATMCard.Rename command has no guard to enforce it only renames "issued" or "active" cards. A retired card should not be renamed.

## Impact

- Can rename retired cards
- Metadata inconsistency
- Card management audit trail unclear

## Fix

Add guard to enforce status == "issued" or status == "active" before allowing rename.
