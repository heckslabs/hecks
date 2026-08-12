# Bug #120: ScheduledPayment.Abandon Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Abandon should check customer is active and account is open before abandoning a payment.

## Fix

Add customer.status == "active" and account.status == "open" guards.
