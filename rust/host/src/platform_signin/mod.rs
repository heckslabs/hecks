//! Signing a site's people in through a platform issuer: the token verifier and the flow around it.
//!
//! A site that lets a platform issuer sign its people in receives, on its callback, a compact JWS
//! signed with Ed25519. The verifier ([`verify`], with [`jws`], [`jwks`], [`jti`] and [`config`])
//! decides whether such a token is genuine, fresh, meant for this site and this environment, and
//! not already used. It is a library of pure functions and small types: no HTTP client, no cookie
//! code, no environment reads, no routes. Its caller supplies the clock, the values from the
//! site's own sign-in cookie, and a [`jwks::JwksFetcher`].
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
//! ## What the verifier is not
//!
//! The verifier does not log, and nothing in it ever formats a token. It is not a session:
//! mapping a verified identity to a member of the site is the job of [`session`].
//!
//! ## The flow around it
//!
//! [`extension`] puts the sign-in on the host's routes, [`handler`] starts and finishes a sign-in,
//! [`settings`] reads the switch and its companions once at boot, and [`cookie`], [`query`] and
//! [`pages`] are the strict edges of the request and response. With the switch unset none of it
//! is installed.

/// Validated settings: the pinned issuer, key set address, site and environment.
pub mod config;
/// The site's own sign-in cookie: how it is written, deleted and strictly read.
pub mod cookie;
/// The host extension that puts the flow on the site's routes.
pub mod extension;
/// The real, bounded fetch of the issuer's key set.
pub mod fetcher;
/// Starting a sign-in and finishing it on the callback.
pub mod handler;
/// The bounded in-memory record that makes each token single-use.
pub mod jti;
/// The issuer's public keys: parsing, thumbprint indexing and a rate-limited cache.
pub mod jwks;
/// Strict compact JWS parsing and canonical base64url.
pub mod jws;
/// The redirects and refusal pages of the flow.
pub mod pages;
/// The callback's query string, read strictly.
pub mod query;
/// Mapping a verified token to a member of the site.
pub mod session;
/// The switch and the settings the flow needs, validated at boot.
pub mod settings;
/// A JSON object reader that refuses repeated keys and deep nesting.
pub mod strict_json;
/// The ordered checks, the stable refusal reasons and the verified claims.
pub mod verify;

#[cfg(test)]
mod attack_tests;
#[cfg(test)]
mod handler_tests;
#[cfg(test)]
mod known_answer_tests;
#[cfg(test)]
mod mapping_tests;
#[cfg(test)]
mod mode_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod ttl_tests;
#[cfg(test)]
mod wiring_support;
