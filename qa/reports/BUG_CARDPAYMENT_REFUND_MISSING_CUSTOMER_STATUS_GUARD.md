# Bug #83: CardPayment.Refund Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Refund should check customer is active before refunding a payment.

## Fix

Add customer.status == "active" guard.
