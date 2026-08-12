# Bug #97: ScheduledPayment.Schedule Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ScheduledPayment.Schedule should check customer is active before scheduling a payment.

## Fix

Add customer.status == "active" guard.
