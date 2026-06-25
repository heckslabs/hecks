        extras = validator["attrs"]["imports"].split("\n").reject(&:empty?)
        lines = ["pub use crate::diagnostic::{Finding, Severity};"]
        extras.each { |imp| lines << "use #{imp};" }
        lines.join("\n") + "\n\n"
