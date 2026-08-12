# Bug #82: CardPayment.Dispute Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.Dispute is a customer-initiated command but doesn't check account is open or customer status.

## Fix

Add account.status == "open" and customer.status == "active" guards.
