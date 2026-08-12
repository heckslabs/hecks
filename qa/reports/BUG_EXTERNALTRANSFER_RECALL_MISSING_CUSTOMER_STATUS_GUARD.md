# Bug #87: ExternalTransfer.Recall Missing Customer Status Guard

**Severity:** HIGH  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ExternalTransfer.Recall should check customer is active before recalling a transfer.

## Fix

Add customer.status == "active" guard.
