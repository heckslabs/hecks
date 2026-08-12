# Bug #100: ScheduledPayment.Retry Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Retry should check customer is active and account is open before retrying a payment.

## Fix

Add customer.status == "active" and account.status == "open" guards.
