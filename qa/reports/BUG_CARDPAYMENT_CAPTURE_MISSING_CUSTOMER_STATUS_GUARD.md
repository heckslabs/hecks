# Bug #81: CardPayment.Capture Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Capture should check customer is active before capturing a payment.

## Fix

Add customer.status == "active" guard.
