//! Hecksagon parser — reads .hecksagon files into the Hecksagon IR.
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/hecksagon_parser_shape/
//! Regenerate: hecks-life specialize hecksagon_parser --output hecks_life/src/hecksagon_parser.rs
//! Contract:  hecks_life/src/specializer/hecksagon_parser.rs (Rust-native)
//! Tests:     hecks_life/tests/hecksagon_parser_test.rs
//!
//! Line-oriented, pattern-match style just like the bluebook parser. Not
//! a full Ruby parser — it recognizes the canonical shapes used by the
//! Ruby DSL builder and the files shipped in `capabilities/*.hecksagon`.
//!
//! Canonical shapes handled:
//!
//!   Hecks.hecksagon "Name" do … end
//!   adapter :memory
//!   adapter :stdout / :stderr / :stdin
//!   adapter :env, keys: ["PATH"]
//!   adapter :fs, root: "."
//!   adapter :shell, name: :foo, command: "git …", ok_exit: 0
//!   adapter :shell, name: :foo, command: "git", args: ["log", "{{sha}}"]
//!   gate "Aggregate", :role do allow :CmdA, :CmdB end
//!   subscribe "OtherDomain"
//!
//! Comments (`#`) and blank lines are skipped. Multi-line adapter calls
//! joined until top-level parens balance. Tiny helpers live in
//! hecksagon_helpers.rs so this file stays under the size budget.
