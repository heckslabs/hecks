# Bug #84: CardPayment.Chargeback Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Chargeback should check customer is active before processing a chargeback.

## Fix

Add customer.status == "active" guard.
