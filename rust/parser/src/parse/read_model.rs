//! The `ReadModel` construct (`lib/hecksagain/bluebook/ir/read_model.rb`,
//! `report` the current spelling — `was: "read_model"`, both answered
//! forever per the rename column). Stage 2+ work: `include` head
//! gathering/pluralization/dedup (`build/read_model.rs`), `group_by`
//! field derivation, and the SAME `where`/`order_by`/`limit`/... words a
//! `Query` admits but landing as OPTION rows here rather than fields
//! (`ReadModel#to_h` omits wheres/order_by/limit — see syntax.bluebook's
//! own comment on why).

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ReadModel.{word}"))
}
