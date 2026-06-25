//! run_host::config — TRANSITIONAL re-export of `runtime::adapter_env`.
//!
//! `map_config` (the `.world`→child-env folder) was RELOCATED into the runtime
//! at `runtime::adapter_env` (i750 out-of-process-adapter pump) so the in-runtime
//! OutboundEvent drain (`reaction::pump_outbound_events`) can resolve a handler's
//! env without depending on this soon-to-retire standalone-host module. This file
//! stays only so `run_host` (the `storehouse host` subcommand, kept alongside the
//! new pump path) keeps compiling ; it is deleted when run_host retires (Phase 3).

pub use crate::runtime::adapter_env::map_config;
