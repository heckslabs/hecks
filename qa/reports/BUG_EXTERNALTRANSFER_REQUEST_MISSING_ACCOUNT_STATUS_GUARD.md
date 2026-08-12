# Bug #38: ExternalTransfer.Request Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 918-931

## Problem

ExternalTransfer.Request command references an Account but has no guard to enforce the account is "open". External transfers should not be initiated from frozen or closed accounts.

## Impact

- Can initiate external transfers from frozen accounts
- Can initiate external transfers from closed accounts
- Frozen account suddenly becomes active
- External transfer audit trail corrupted

## Fix

Add guard to enforce account.status == "open" before allowing external transfer request.
