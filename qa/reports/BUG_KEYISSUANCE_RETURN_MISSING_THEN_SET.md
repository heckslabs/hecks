# Bug #122: KeyIssuance.Return Missing then_set :serial

**Severity:** HIGH  
**Type:** Missing Attribute Persistence  

## Problem

KeyIssuance.Return accepts a serial attribute but never persists it to the key record.

## Fix

Add `then_set :serial, to: :serial` to persist the serial to the key.
