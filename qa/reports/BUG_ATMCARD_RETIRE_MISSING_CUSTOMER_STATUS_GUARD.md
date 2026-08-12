# Bug #110: ATMCard.Retire Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ATMCard.Retire should check customer is active before retiring a card.

## Fix

Add customer.status == "active" guard.
