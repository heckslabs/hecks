# Bug #95: CardPayment.Void Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Void should check customer is active before voiding a payment.

## Fix

Add customer.status == "active" guard.
