# Bug #117: LedgerEntry.Reverse Missing Account/Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

LedgerEntry.Reverse (nested entity in Account) should check account is open and customer is active before reversing a ledger entry.

## Fix

Add account.status == "open" and account.customer.status == "active" guards.
