        <<~RS
          pub struct Report {
              pub findings: Vec<Finding>,
          }

          impl Report {
              pub fn errors(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Error).count()
              }
              pub fn passes(&self) -> bool { self.errors() == 0 }
          }

        RS
