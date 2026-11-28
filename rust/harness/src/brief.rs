//! A role's brief: what a session opened for one of the crew's roles is first told.
//!
//! A role file (`.claude/agents/<role>.md`, generated from the Agents bluebook) opens with the
//! frontmatter Claude Code reads, then the role in prose. A harness session reads none of the
//! frontmatter, and its steps name the shell's mail commands, which the session does not have. So
//! the brief is a short preamble that says how mail works in a harness run and which tools the
//! session holds, then the role's prose, unchanged.

use crate::protocol::SEND_TOOL;

/// What a role's session is told before its role: how mail works, then the tools it holds.
pub fn preamble(tools: &[String]) -> String {
    format!("{} {}", mail(), held(tools))
}

/// How mail works in a harness run, the same for every role.
fn mail() -> String {
    format!(
        "You run as a harness session. You reach other sessions with {SEND_TOOL}(to, text, about). A message \
         reaches you as a turn that starts \"Message <id> from <name>\", and a message the harness \
         could not deliver comes back to you as a turn that starts \"Notice from harness\". Where \
         your role says to read your inbox or to run exe/hecks Message.send!, {SEND_TOOL} \
         replaces it: name the session in to, and put the id of the message you answer or relay \
         in about. Where it says to leave what you found on a message with Message.note!, send \
         what you found to the orchestrator, about that message."
    )
}

/// The tools the session may use beside the mail, as its role names them; the harness refuses
/// every other.
fn held(tools: &[String]) -> String {
    if tools.is_empty() {
        format!("{SEND_TOOL} is your one tool: the harness refuses every other.")
    } else {
        format!(
            "Beside {SEND_TOOL}, your tools are the ones your role names: {}. The harness refuses \
             every other.",
            tools.join(", ")
        )
    }
}

/// The brief for the role whose file is `role_file` and whose session holds `tools`: the preamble,
/// a blank line, then the file without its frontmatter.
pub fn of_role(role_file: &str, tools: &[String]) -> String {
    format!("{}\n\n{}", preamble(tools), body(role_file).trim())
}

/// What a session reopened in a standing seat is told before the handover its seat's last session
/// left.
pub const HANDOVER: &str = "Handover from the last session in this seat:";

/// A session's first turn: its brief, then, when its seat's last session left a handover (what it
/// said at the end of its last turn that said something), a blank line, [`HANDOVER`] and the
/// handover, so the new session takes up where the last one stopped. With no handover, or a blank
/// one, the brief alone.
pub fn opening(brief: &str, handover: Option<&str>) -> String {
    handover
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map_or_else(
            || brief.to_string(),
            |text| format!("{brief}\n\n{HANDOVER}\n\n{text}"),
        )
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
    fn a_first_session_is_told_its_brief_alone() {
        assert_eq!(
            opening("You are the scrum master.", None),
            "You are the scrum master."
        );
    }

    #[test]
    fn a_blank_handover_leaves_the_brief_alone() {
        assert_eq!(
            opening("You are the scrum master.", Some(" \n")),
            "You are the scrum master."
        );
    }

    #[test]
    fn a_reopened_session_is_told_its_brief_then_the_handover() {
        assert_eq!(
            opening("You are the scrum master.", Some("coder-1 waits on the lead.\n")),
            "You are the scrum master.\n\nHandover from the last session in this seat:\n\ncoder-1 waits on the lead."
        );
    }

    fn bash() -> Vec<String> {
        vec!["Bash".to_string()]
    }

    #[test]
    fn opens_with_how_mail_works_in_a_harness_run() {
        assert!(of_role(FILE, &bash()).starts_with(
            "You run as a harness session. You reach other sessions with send_message"
        ));
    }

    #[test]
    fn says_where_a_note_on_a_message_goes() {
        assert!(preamble(&bash())
            .contains("send what you found to the orchestrator, about that message."));
    }

    #[test]
    fn names_the_tools_the_role_holds() {
        assert!(preamble(&["Read".to_string(), "Bash".to_string()])
            .ends_with("your tools are the ones your role names: Read, Bash. The harness refuses every other."));
    }

    #[test]
    fn says_send_message_is_the_one_tool_of_a_role_that_names_none() {
        assert!(preamble(&[])
            .ends_with("send_message is your one tool: the harness refuses every other."));
    }

    #[test]
    fn carries_the_role_unchanged_after_the_preamble() {
        assert!(of_role(FILE, &bash())
            .ends_with("\n\nYou are the staff engineer role.\n\n## Limits\n\nRelay only."));
    }

    #[test]
    fn leaves_out_the_frontmatter() {
        assert!(!of_role(FILE, &bash()).contains("tools: Bash"));
    }

    #[test]
    fn takes_a_file_with_no_frontmatter_whole() {
        assert!(of_role("You are the coder.\n", &[]).ends_with("\n\nYou are the coder."));
    }

    #[test]
    fn takes_a_file_whose_frontmatter_never_closes_whole() {
        assert!(of_role("---\nname: x\n", &[]).ends_with("---\nname: x"));
    }
}
