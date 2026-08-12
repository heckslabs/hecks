# Bug: CardPayment.Reverse Missing Status Guard

**Severity:** CRITICAL  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 793-795

## Problem

CardPayment.Reverse command has no guard to enforce it only reverses captured payments. The lifecycle declares `transition "Reverse" => "reversed", from: "captured"` but the command lacks guards.

## Impact

- Can reverse non-captured payments
- Can reverse authorized payments
- Can double-reverse the same payment
- Invalid state transitions allowed

## Fix

Add guard to enforce status == "captured" before allowing reverse.
