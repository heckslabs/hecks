//! A role's session: the brief it is told, the tools it may use and the model it runs on.
//!
//! A role file (`.claude/agents/<role>.md`, in the checkout whose crew it is) opens with the
//! frontmatter Claude Code reads. A harness session takes two lines of it: `tools`, the tools the
//! supervisor lets the session use (beside `send_message`, which every session has), and `model`.
//! A role whose tools are `*` is started by hand by an owner, with no routing guard, so it is not
//! opened in a harness run.

use std::fs;
use std::path::Path;

use crate::brief;
use crate::json::Value;

/// A role, as a session opened for it holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Role {
    /// What the session is first told.
    pub brief: String,
    /// The tools the session may use, as the role file names them.
    pub tools: Vec<String>,
    /// The model the session runs on; Claude Code's own default when `None`.
    pub model: Option<String>,
}

impl Role {
    /// The role whose file is `role_file`.
    ///
    /// # Errors
    ///
    /// When the role names every tool (`*`): that role is an owner's, started by hand.
    pub fn of_file(role_file: &str) -> Result<Self, String> {
        let tools: Vec<String> = field(role_file, "tools")
            .map(|line| {
                line.split(',')
                    .map(str::trim)
                    .filter(|tool| !tool.is_empty())
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        if tools.iter().any(|tool| tool == "*") {
            return Err(
                "a role with every tool is started by hand by an owner, not in a harness run"
                    .to_string(),
            );
        }
        let model = field(role_file, "model")
            .filter(|name| !name.is_empty() && *name != "inherit")
            .map(ToString::to_string);
        Ok(Self {
            brief: brief::of_role(role_file, &tools),
            tools,
            model,
        })
    }

    /// The role as JSON: `{"brief": …, "tools": […], "model": …}`, `model` null for the default.
    pub fn to_json(&self) -> String {
        Value::object(vec![
            ("brief", Value::text(self.brief.clone())),
            (
                "tools",
                Value::Array(
                    self.tools
                        .iter()
                        .map(|tool| Value::text(tool.clone()))
                        .collect(),
                ),
            ),
            ("model", self.model.clone().map_or(Value::Null, Value::text)),
        ])
        .to_json()
    }
}

/// Whether a session holding `tools` may use `tool` with `input`. A tool named bare allows every
/// use of it; `Agent(<type>)` allows the Agent tool only for that subagent type; `mcp__<server>`
/// allows every tool of that MCP server.
pub fn permits(tools: &[String], tool: &str, input: &Value) -> bool {
    tools.iter().any(|named| {
        match named
            .strip_suffix(')')
            .and_then(|rest| rest.split_once('('))
        {
            Some((name, kind)) => name == tool && input.str_at("subagent_type") == Some(kind),
            None => {
                named == tool
                    || (named.starts_with("mcp__") && tool.starts_with(&format!("{named}__")))
            }
        }
    })
}

/// The crew a harness run brings up: every role with a file `<role>.md` in `agents`, by name,
/// but the owners' roles, which are started by hand.
///
/// # Errors
///
/// When `agents` or a role file in it cannot be read.
pub fn crew(agents: &Path) -> Result<Vec<String>, String> {
    let unread = |error: std::io::Error| format!("cannot read {}: {error}", agents.display());
    let mut names = Vec::new();
    for entry in fs::read_dir(agents).map_err(unread)? {
        let path = entry.map_err(unread)?.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
            continue;
        }
        let text = fs::read_to_string(&path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        if let (Ok(_), Some(name)) = (
            Role::of_file(&text),
            path.file_stem().and_then(|stem| stem.to_str()),
        ) {
            names.push(name.to_string());
        }
    }
    names.sort();
    Ok(names)
}

/// The value of a frontmatter line `<key>: <value>`, trimmed, when the file opens with frontmatter.
fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let rest = text.strip_prefix("---\n")?;
    let front = &rest[..rest.find("\n---\n").unwrap_or(rest.len())];
    front.lines().find_map(|line| {
        line.strip_prefix(key)
            .and_then(|after| after.strip_prefix(':'))
            .map(str::trim)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;

    const CODER: &str = "---\nname: coder\ntools: Read, Edit, Bash, Agent(Explore)\nmodel: sonnet\n---\n\nYou are the coder.\n";

    fn input(text: &str) -> Value {
        json::parse(text).unwrap()
    }

    #[test]
    fn reads_the_tools_and_the_model_from_the_frontmatter() {
        let role = Role::of_file(CODER).unwrap();
        assert_eq!(
            (role.tools, role.model),
            (
                vec![
                    "Read".into(),
                    "Edit".into(),
                    "Bash".into(),
                    "Agent(Explore)".into()
                ],
                Some("sonnet".into())
            )
        );
    }

    #[test]
    fn leaves_an_inherited_model_to_claude_code() {
        let role = Role::of_file("---\nname: x\ntools: Bash\nmodel: inherit\n---\nx\n").unwrap();
        assert_eq!(role.model, None);
    }

    #[test]
    fn refuses_a_role_with_every_tool() {
        assert!(Role::of_file("---\nname: owner\ntools: *\n---\nx\n").is_err());
    }

    #[test]
    fn holds_no_tools_when_the_file_names_none() {
        assert!(Role::of_file("You are the coder.\n")
            .unwrap()
            .tools
            .is_empty());
    }

    #[test]
    fn permits_a_tool_the_role_names() {
        let tools = Role::of_file(CODER).unwrap().tools;
        assert!(permits(&tools, "Edit", &input(r#"{"file_path":"a.rb"}"#)));
    }

    #[test]
    fn refuses_a_tool_the_role_does_not_name() {
        let tools = Role::of_file(CODER).unwrap().tools;
        assert!(!permits(&tools, "Write", &input(r#"{"file_path":"a.rb"}"#)));
    }

    #[test]
    fn permits_the_agent_tool_only_for_the_subagent_type_named() {
        let tools = Role::of_file(CODER).unwrap().tools;
        assert_eq!(
            (
                permits(&tools, "Agent", &input(r#"{"subagent_type":"Explore"}"#)),
                permits(&tools, "Agent", &input(r#"{"subagent_type":"coder"}"#))
            ),
            (true, false)
        );
    }

    #[test]
    fn permits_every_tool_of_a_named_mcp_server() {
        let tools = vec!["mcp__hecks".to_string()];
        assert_eq!(
            (
                permits(&tools, "mcp__hecks__explain", &Value::Null),
                permits(&tools, "mcp__other__explain", &Value::Null)
            ),
            (true, false)
        );
    }

    #[test]
    fn brings_up_every_role_but_the_owners_by_name() {
        let agents =
            std::env::temp_dir().join(format!("hecks-harness-crew-{}", std::process::id()));
        fs::create_dir_all(&agents).unwrap();
        fs::write(agents.join("reviewer.md"), CODER).unwrap();
        fs::write(agents.join("coder.md"), CODER).unwrap();
        fs::write(
            agents.join("owner.md"),
            "---\nname: owner\ntools: *\n---\nx\n",
        )
        .unwrap();
        fs::write(agents.join("notes.txt"), CODER).unwrap();
        let crew = crew(&agents);
        fs::remove_dir_all(&agents).unwrap();
        assert_eq!(crew.unwrap(), vec!["coder".to_string(), "reviewer".into()]);
    }

    #[test]
    fn refuses_a_crew_whose_roles_cannot_be_read() {
        assert!(crew(Path::new("/nonexistent/hecks-harness-agents")).is_err());
    }

    #[test]
    fn writes_the_role_as_json() {
        let role = Role {
            brief: "b".into(),
            tools: vec!["Bash".into()],
            model: None,
        };
        assert_eq!(
            role.to_json(),
            r#"{"brief":"b","tools":["Bash"],"model":null}"#
        );
    }
}
