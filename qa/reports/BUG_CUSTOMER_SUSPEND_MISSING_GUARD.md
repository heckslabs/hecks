# Bug #21: Customer.Suspend Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 106-116

## Problem

Customer.Suspend command has no guard to enforce it only suspends "active" customers. The lifecycle declares `transition "Suspend" => "suspended", from: "active"` but the command lacks guards.

## Impact

- Can suspend already-suspended customers
- Can suspend closed customers
- Compliance audit trail corrupted
- Customer dispute on re-suspension

## Fix

Add guard to enforce status == "active" before allowing suspend.
