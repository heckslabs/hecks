# Bug #96: CardPayment.Reverse Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Reverse should check customer is active before reversing a payment.

## Fix

Add customer.status == "active" guard.
