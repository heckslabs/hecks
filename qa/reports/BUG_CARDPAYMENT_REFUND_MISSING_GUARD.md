# Bug: CardPayment.Refund Missing Status Guard

**Severity:** CRITICAL  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 788-790

## Problem

CardPayment.Refund command has no guard to enforce it only refunds captured payments. The lifecycle declares `transition "Refund" => "refunded", from: "captured"` but the command lacks guards.

## Impact

- Can refund non-captured payments
- Can refund authorized payments that were never captured
- Can double-refund the same payment
- Refund money not actually charged

## Fix

Add guard to enforce status == "captured" before allowing refund.
