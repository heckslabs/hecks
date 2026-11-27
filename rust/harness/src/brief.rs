//! A role's brief: what a session opened for one of the crew's roles is first told.
//!
//! A role file (`.claude/agents/<role>.md`, generated from the Agents bluebook) opens with the
//! frontmatter Claude Code reads, then the role in prose. A harness session reads none of the
//! frontmatter, and its steps name the shell's mail commands, which the session does not have. So
//! the brief is a short preamble that says how mail works in a harness run, then the role's prose,
//! unchanged.

use crate::protocol::SEND_TOOL;

/// What every role's session is told before its role.
pub fn preamble() -> String {
    format!(
        "You run as a harness session. Your one tool is {SEND_TOOL}(to, text, about). A message \
         reaches you as a turn that starts \"Message <id> from <name>\", and a message the harness \
         could not deliver comes back to you as a turn that starts \"Notice from harness\". Where \
         your role says to read your inbox or to run exe/hecks Message.send!, {SEND_TOOL} \
         replaces it: name the session in to, and put the id of the message you answer or relay \
         in about. Where it says to leave what you found on a message with Message.note!, send \
         what you found to the orchestrator, about that message."
    )
}

/// The brief for the role whose file is `role_file`: the preamble, a blank line, then the file
/// without its frontmatter.
pub fn of_role(role_file: &str) -> String {
    format!("{}\n\n{}", preamble(), body(role_file).trim())
}

/// The file after its frontmatter: everything after the second `---` line, when the first line is
/// `---`; the whole file otherwise.
fn body(text: &str) -> &str {
    text.strip_prefix("---\n")
        .and_then(|rest| rest.find("\n---\n").map(|end| &rest[end + 5..]))
        .unwrap_or(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE: &str = "---\nname: staff-engineer\ntools: Bash\n---\n\nYou are the staff engineer role.\n\n## Limits\n\nRelay only.\n";

    #[test]
    fn opens_with_how_mail_works_in_a_harness_run() {
        assert!(of_role(FILE)
            .starts_with("You run as a harness session. Your one tool is send_message"));
    }

    #[test]
    fn says_where_a_note_on_a_message_goes() {
        assert!(preamble().contains("send what you found to the orchestrator, about that message."));
    }

    #[test]
    fn carries_the_role_unchanged_after_the_preamble() {
        assert!(of_role(FILE)
            .ends_with("\n\nYou are the staff engineer role.\n\n## Limits\n\nRelay only."));
    }

    #[test]
    fn leaves_out_the_frontmatter() {
        assert!(!of_role(FILE).contains("tools: Bash"));
    }

    #[test]
    fn takes_a_file_with_no_frontmatter_whole() {
        assert!(of_role("You are the coder.\n").ends_with("\n\nYou are the coder."));
    }

    #[test]
    fn takes_a_file_whose_frontmatter_never_closes_whole() {
        assert!(of_role("---\nname: x\n").ends_with("---\nname: x"));
    }
}
