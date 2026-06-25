#[derive(Debug, PartialEq)]
pub enum TestStatus { Pass, Fail, Error }

pub struct TestRun {
    pub description: String,
    pub status: TestStatus,
    pub message: Option<String>,
}

impl TestRun {
    fn pass(desc: &str) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Pass, message: None }
    }
    fn fail(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Fail, message: Some(msg.into()) }
    }
    fn error(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Error, message: Some(msg.into()) }
    }
}

pub struct SuiteResult {
    pub runs: Vec<TestRun>,
}

impl SuiteResult {
    pub fn passed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Pass).count() }
    pub fn failed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Fail).count() }
    pub fn errored(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Error).count() }
    pub fn all_passed(&self) -> bool { self.failed() == 0 && self.errored() == 0 }
}

