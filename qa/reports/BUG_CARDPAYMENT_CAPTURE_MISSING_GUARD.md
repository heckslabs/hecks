# Bug: CardPayment.Capture Missing Status Guard

**Severity:** CRITICAL  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 777-780

## Problem

CardPayment.Capture command has no guard to enforce it only captures authorized payments. The lifecycle declares `transition "Capture" => "captured", from: "authorized"` but the command lacks `given` guards.

## Impact

- Can capture already-captured payments
- Can capture voided, reversed, or disputed payments  
- Double-charging customer is possible
- Payment state machine completely unenforced

## Fix

Add guard to enforce status == "authorized" before allowing capture.
