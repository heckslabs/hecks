# Bug #72: Account.Freeze Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Account.Freeze should check customer is active before freezing.

## Fix

Add customer.status == "active" guard.
