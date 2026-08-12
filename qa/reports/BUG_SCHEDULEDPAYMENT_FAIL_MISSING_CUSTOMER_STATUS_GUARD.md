# Bug #99: ScheduledPayment.Fail Missing Customer/Account Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Fail should check customer is active and account is open before recording a payment failure.

## Fix

Add customer.status == "active" and account.status == "open" guards.
