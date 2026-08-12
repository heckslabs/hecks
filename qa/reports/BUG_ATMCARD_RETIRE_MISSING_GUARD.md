# Bug #19: ATMCard.Retire Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 587-593

## Problem

ATMCard.Retire command has no guard to enforce it only retires "issued" or "active" cards. The lifecycle declares `transition "Retire" => "retired", from: ["issued", "active"]` but the command lacks guards.

## Impact

- Can retire already-retired cards
- Card state transitions unknown
- Audit trail corrupted

## Fix

Add guard to enforce status == "issued" or status == "active" before allowing retire.
