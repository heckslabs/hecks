# Bug #23: Customer.Close Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 128-134

## Problem

Customer.Close command has no guard to enforce it only closes "active" or "suspended" customers. The lifecycle declares `transition "Close" => "closed", from: ["active", "suspended"]` but the command lacks guards.

## Impact

- Can close already-closed customers
- Customer record corrupted
- Relationship termination audit trail unclear
- Double-closing attempt undetected

## Fix

Add guard to enforce status == "active" or status == "suspended" before allowing close.
