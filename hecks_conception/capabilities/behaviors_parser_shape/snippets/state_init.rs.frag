// Snippet: state_init — the lines between `pub fn parse(...) {`
// and the `while i < lines.len()` loop. Covers the TestSuite
// struct-literal initialization + loop-var declarations.
    let mut suite = TestSuite {
        name: String::new(),
        vision: None,
        tests: vec![],
        loads: vec![],
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;
