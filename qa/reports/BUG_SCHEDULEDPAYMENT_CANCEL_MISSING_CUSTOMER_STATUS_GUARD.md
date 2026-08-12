# Bug #98: ScheduledPayment.Cancel Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Cancel should check customer is active and account is open before canceling a payment.

## Fix

Add customer.status == "active" and account.status == "open" guards.
