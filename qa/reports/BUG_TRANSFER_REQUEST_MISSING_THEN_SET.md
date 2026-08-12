# Bug #128: Transfer.Request Missing then_set :reference

**Severity:** CRITICAL  
**Type:** Missing Attribute Persistence  

## Problem

Transfer.Request accepts a reference attribute (used as the transfer's identity) but never persists it.

## Fix

Add `then_set :reference, to: :reference`.
