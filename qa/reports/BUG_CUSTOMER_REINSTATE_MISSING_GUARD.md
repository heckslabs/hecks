# Bug #22: Customer.Reinstate Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 118-126

## Problem

Customer.Reinstate command has no guard to enforce it only reinstates "suspended" customers. The lifecycle declares `transition "Reinstate" => "active", from: "suspended"` but the command lacks guards.

## Impact

- Can reinstate already-active customers
- Can reinstate closed customers
- Compliance audit trail corrupted
- Resets standing without justification

## Fix

Add guard to enforce status == "suspended" before allowing reinstate.
