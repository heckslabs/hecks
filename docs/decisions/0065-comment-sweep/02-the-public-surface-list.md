# 02: The public surface list

**Status:** Open · **Type:** grilling (HITL), with a research subagent to inventory first · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0065 comment sweep](../0065-comment-sweep-map.md)

## Question

Ticket 01 makes public the default and requires docs only on untagged public items, with internals tagged `:nodoc:` in Ruby and `#[doc(hidden)]` or `pub(crate)` in Rust. No tag of either kind exists in the repository today, and the YARD `@api` tag is unused. So every class, module and Rust item is untagged, and the boundary has to be drawn once and applied by script.

Decide:

1. **What defines public.** The current proposal is everything the README, the generated DSL reference (`docs/implemented/reference/index.md`), the guides in `docs/implemented/guides/` and the `bin/` commands in `docs/tools.md` name or show. Is that the whole definition, or do runtime entry points a project calls without the docs naming them also count?
2. **How the list is derived.** By script from those documents (a constant or method named there is public), or by hand.
3. **The unit of tagging.** One `:nodoc:` per class or module (cheap, coarse), or per method where a public class has internal methods.
4. **Boundary cases.** Ports and adapter base classes that a project extends, the DSL builder classes behind each keyword, the Rust `pub` items that are only public for crate reasons, and the parser and IR types shared across crates.
5. **What happens to the Rust `pub` items** that are neither documented as public nor `pub(crate)` today.

The inventory (counts of classes and modules by location, and which ones the documents name) is research and can be done first by a subagent.

## Working recommendation (not a decision)

Derive the list by script from the four sources above, tag per class or module, and treat anything a project can subclass or call through a documented keyword as public. Rust items are public only when reachable from the documented API; the rest become `pub(crate)` where the compiler allows it and `#[doc(hidden)]` where it does not. Boundary cases are decided one by one in the ticket and recorded as a short list.

## Decision

Open.
