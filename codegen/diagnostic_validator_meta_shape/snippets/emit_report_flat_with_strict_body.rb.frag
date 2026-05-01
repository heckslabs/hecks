        <<~RS
          pub struct Report {
              pub findings: Vec<Finding>,
          }

          impl Report {
              pub fn errors(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Error).count()
              }
              pub fn warnings(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Warning).count()
              }
              pub fn passes(&self, strict: bool) -> bool {
                  if self.errors() > 0 { return false; }
                  if strict && self.warnings() > 0 { return false; }
                  true
              }
          }

        RS
