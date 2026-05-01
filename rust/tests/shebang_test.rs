//! Regression test — parser tolerates a `#!...\n` shebang line.
//!
//! A .bluebook marked `chmod +x` with `#!/usr/bin/env hecks-life run` at
//! the top must parse identically to the same file without that line.
//! This pins the behavior so future parser rewrites don't regress it.

use hecks_life::parser;

const WITH_SHEBANG: &str = "#!/usr/bin/env hecks-life run\nHecks.bluebook \"Tiny\" do\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n";

const WITHOUT_SHEBANG: &str = "Hecks.bluebook \"Tiny\" do\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n";

#[test]
fn shebang_line_is_stripped_before_parse() {
    let with = parser::parse(WITH_SHEBANG);
    let without = parser::parse(WITHOUT_SHEBANG);
    assert_eq!(with.name, without.name);
    assert_eq!(with.aggregates.len(), without.aggregates.len());
    assert_eq!(with.aggregates[0].name, without.aggregates[0].name);
    assert_eq!(with.aggregates[0].commands.len(), 1);
}

#[test]
fn strip_shebang_is_exposed_as_a_helper() {
    assert_eq!(parser::strip_shebang("#!hecks-life\nHecks.bluebook \"X\" do\nend\n"),
               "Hecks.bluebook \"X\" do\nend\n");
    assert_eq!(parser::strip_shebang("no shebang\nhere\n"), "no shebang\nhere\n");
    assert_eq!(parser::strip_shebang("#!only_line_no_newline"), "");
}
