# Bug #107: Withdrawal.Dispute Missing Account/Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Withdrawal.Dispute (nested entity in ATMCard) should check account is open and customer is active before disputing a withdrawal.

## Fix

Add account.status == "open" and account.customer.status == "active" guards.
