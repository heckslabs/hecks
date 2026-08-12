# Bug #11: ExternalTransfer.Send Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 916-919

## Problem

ExternalTransfer.Send command has no guard to enforce it only sends "requested" transfers. The lifecycle declares `transition "Send" => "sent", from: "requested"` but the command lacks guards.

## Impact

- Can send already-sent transfers
- Can send recalled or returned transfers
- Money sent twice to beneficiary
- External account corruption

## Fix

Add guard to enforce status == "requested" before allowing send.
