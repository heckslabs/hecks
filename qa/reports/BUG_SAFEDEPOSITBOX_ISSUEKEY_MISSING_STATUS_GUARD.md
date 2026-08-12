# Bug #45: SafeDepositBox.IssueKey Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1286-1296

## Problem

SafeDepositBox.IssueKey command has no guard to enforce it only issues keys for "rented" boxes. You cannot issue a key for a vacant box or a surrendered box.

## Impact

- Can issue keys for vacant boxes
- Can issue keys for surrendered boxes
- Vault access control corrupted
- Orphaned keys in system

## Fix

Add guard to enforce status == "rented" before allowing key issuance.
