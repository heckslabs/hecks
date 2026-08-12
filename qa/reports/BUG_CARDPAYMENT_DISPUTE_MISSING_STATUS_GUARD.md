# Bug #41: CardPayment.Dispute Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 823-846

## Problem

CardPayment.Dispute command has no guard to enforce it only disputes "captured" or "refunded" payments. The lifecycle declares `transition "Dispute" => "disputed", from: ["captured", "refunded"]` but the command lacks guards.

## Impact

- Can dispute authorized (not yet captured) payments
- Can dispute already-disputed payments
- Can dispute voided payments
- Chargeback audit trail corrupted

## Fix

Add guard to enforce status == "captured" or status == "refunded" before allowing dispute.
