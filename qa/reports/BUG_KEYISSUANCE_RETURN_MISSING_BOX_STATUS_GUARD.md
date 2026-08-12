# Bug #58: KeyIssuance.Return Missing Box Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1224-1233

## Problem

KeyIssuance.Return command has a guard on key status but no guard to enforce the box is "rented". Keys can only be returned for rented boxes, not vacant or surrendered ones.

## Impact

- Can return keys for vacant boxes
- Can return keys for surrendered boxes
- Vault access control corrupted
- Key tracking corrupted

## Fix

Add guard to enforce box status == "rented" before allowing key return.
