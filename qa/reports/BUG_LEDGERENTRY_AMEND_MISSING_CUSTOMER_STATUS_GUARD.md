# Bug #116: LedgerEntry.Amend Missing Account/Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

LedgerEntry.Amend (nested entity in Account) should check account is open and customer is active before amending a ledger entry.

## Fix

Add account.status == "open" and account.customer.status == "active" guards.
