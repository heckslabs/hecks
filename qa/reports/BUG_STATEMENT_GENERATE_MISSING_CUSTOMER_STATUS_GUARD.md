# Bug #121: Statement.Generate Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Statement.Generate should check customer is active before generating a statement.

## Fix

Add customer.status == "active" guard.
