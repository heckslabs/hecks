# Bug #108: ATMCard.Rename Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ATMCard.Rename should check customer is active before renaming a card.

## Fix

Add customer.status == "active" guard.
