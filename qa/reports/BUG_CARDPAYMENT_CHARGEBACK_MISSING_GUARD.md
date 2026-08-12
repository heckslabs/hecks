# Bug: CardPayment.Chargeback Missing Status Guard

**Severity:** CRITICAL  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 822-825

## Problem

CardPayment.Chargeback command has no guard to enforce it only chargebacks disputed payments. The lifecycle declares `transition "Chargeback" => "charged_back", from: "disputed"` but the command lacks guards.

## Impact

- Can chargeback non-disputed payments
- Can chargeback authorized, captured, or refunded payments
- Chargeback issued for charges never disputed
- Fraud vector enabled

## Fix

Add guard to enforce status == "disputed" before allowing chargeback.
