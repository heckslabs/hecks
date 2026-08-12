# Bug #90: Transfer.Debited Missing Source Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Debited should check source customer is active before recording the debit.

## Fix

Add source.customer.status == "active" guard.
