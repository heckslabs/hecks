# Bug #125: CardPayment.Authorize Missing then_set :authorisation

**Severity:** CRITICAL  
**Type:** Missing Attribute Persistence  

## Problem

CardPayment.Authorize accepts an authorisation attribute (used as the payment's identity) but never persists it.

## Fix

Add `then_set :authorisation, to: :authorisation`.
