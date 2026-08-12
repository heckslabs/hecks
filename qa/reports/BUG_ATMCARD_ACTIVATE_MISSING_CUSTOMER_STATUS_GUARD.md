# Bug #109: ATMCard.Activate Missing Customer Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  

## Problem

ATMCard.Activate should check customer is active before activating a card.

## Fix

Add customer.status == "active" guard.
