# Bug #115: CardPayment.RejectDispute Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

CardPayment.RejectDispute should check customer is active before rejecting a dispute.

## Fix

Add customer.status == "active" guard.
