# Bug #92: Transfer.Credited Missing Destination Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Transfer.Credited should check destination customer is active before recording the credit.

## Fix

Add destination.customer.status == "active" guard.
