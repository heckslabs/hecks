# Bug: CardPayment.RejectDispute Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 827-830

## Problem

CardPayment.RejectDispute command has no guard to enforce it only rejects disputed payments. The lifecycle declares `transition "RejectDispute" => "captured", from: "disputed"` but the command lacks guards.

## Impact

- Can reject disputes on non-disputed payments
- Reject dispute for charge never disputed
- Dispute resolution process broken
- Invalid state transitions allowed

## Fix

Add guard to enforce status == "disputed" before allowing reject dispute.
