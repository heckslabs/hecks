# Bug #119: Visit.Annotate Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

Visit.Annotate (nested entity in SafeDepositBox) should check customer is active before annotating a visit.

## Fix

Add customer.status == "active" guard via parent.customer.
