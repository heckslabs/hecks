# Bug: CardPayment.Void Missing Status Guard

**Severity:** CRITICAL  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 783-786

## Problem

CardPayment.Void command has no guard to enforce it only voids authorized payments. The lifecycle declares `transition "Void" => "voided", from: "authorized"` but the command lacks guards.

## Impact

- Can void already-voided, captured, or refunded payments
- Payment state machine completely unenforced
- Invalid state transitions allowed

## Fix

Add guard to enforce status == "authorized" before allowing void.
