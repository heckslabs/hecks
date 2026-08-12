# Bug #74: ScheduledPayment.Execute Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Execute should check both customer is active AND account is open before executing a scheduled payment.

## Fix

Add customer.status == "active" and account.status == "open" guards.
