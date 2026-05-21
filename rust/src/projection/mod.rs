//! Projection — emit non-Rust / non-Ruby targets from Hecks IR.
//!
//! Bluebooks project to runtimes (Ruby + Rust today). Hecksagons project
//! to cloud infrastructure : Terraform HCL, CloudFormation YAML, AWS
//! CDK, Pulumi, Kubernetes manifests. The `projection` module is the
//! home for those projectors.
//!
//! Phase 1 (i693) implements the Terraform HCL projector ; sibling
//! projectors for the other targets will live alongside as
//! `projection::cloudformation`, `projection::cdk`, etc.
//!
//! Each projector is a pure walk over the parsed IR — no file I/O
//! inside the projector itself. The caller (the `storehouse project`
//! CLI subcommand) reads source files into IR, hands them to the
//! projector, and writes the emitted string back to disk.
//!
//! The bluebook contract for the Terraform projector lives at :
//!   hecks_conception/aggregates/framework/projection/terraform.bluebook
//!
//! Parity between that bluebook and this code is enforced by the
//! integration test in rust/tests/terraform_projection_test.rs which
//! diff-tests against golden HCL in
//! rust/tests/fixtures/terraform_projection/.

pub mod terraform;
