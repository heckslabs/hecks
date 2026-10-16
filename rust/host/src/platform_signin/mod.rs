//! Verification of platform sign-in tokens, and nothing else.
//!
//! A site that lets a platform issuer sign its people in receives, on its callback, a compact JWS
//! signed with Ed25519. This module decides whether such a token is genuine, fresh, meant for this
//! site and this environment, and not already used. It is a library of pure functions and small
//! types: no HTTP client, no cookie code, no environment reads at boot, no routes. The caller
//! supplies the clock, the values from the site's own sign-in cookie, and a [`jwks::JwksFetcher`].
//!
//! ## Why a reference implementation elsewhere
//!
//! The issuer's own verifier (the Ruby one in the platform repository) is the reference. This
//! module gives the same verdict and the same stable refusal code, in the same check order, for
//! every vector in the shared known-answer file (`tests/fixtures/platform_signin_vectors.json`).
//! The check order is part of the contract: an attacker who can fail two checks at once must learn
//! only about the first, and a request that fails an early check must never spend the token's
//! single-use identifier.
//!
//! ## What it is not
//!
//! It does not log, and nothing in it ever formats a token. It is not a session: mapping a verified
//! identity to a member of the site is the caller's job.

pub mod config;
pub mod jti;
pub mod jwks;
pub mod jws;
pub mod strict_json;
pub mod verify;

#[cfg(test)]
mod attack_tests;
#[cfg(test)]
mod known_answer_tests;
#[cfg(test)]
mod test_support;
