# Bug #80: CardPayment.Authorize Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Authorize should check customer is active before authorizing a payment.

## Fix

Add customer.status == "active" guard.
