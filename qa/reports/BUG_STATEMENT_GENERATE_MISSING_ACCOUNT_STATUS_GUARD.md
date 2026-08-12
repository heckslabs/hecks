# Bug #47: Statement.Generate Missing Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1444-1456

## Problem

Statement.Generate command references an Account but has no guard to enforce the account is "open". Statements should only be generated for open accounts, not frozen or closed ones.

## Impact

- Can generate statements for frozen accounts
- Can generate statements for closed accounts
- Statement audit trail corrupted
- Reporting accuracy compromised

## Fix

Add guard to enforce account.status == "open" before allowing statement generation.
