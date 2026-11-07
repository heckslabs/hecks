// The identity port (`identity_generation`): where a run key comes from when a reaction triggers a
// creating command that requires a `run` and names none, as Ruby's
// `ReactionInvocation::RunKeys.with_minted_run` mints it from the bound adapter. The kernel owns
// no randomness, so the host answers: the ids it will hand out ride in the kernel's input
// (`"identity"`), beside the table of commands that require a `run` (`"run_required"`).

use serde_json::{json, Value};

/// What mints an identity: a random UUID in a deployment, a counter in a test.
pub trait IdentityPort {
    fn uuid(&self) -> String;
}

/// The process's identity port: a random version 4 UUID, as Ruby's `SecureRandomIdentity` mints.
pub struct ProcessIdentity;

impl IdentityPort for ProcessIdentity {
    fn uuid(&self) -> String {
        uuid::Uuid::new_v4().to_string()
    }
}

/// How many ids one kernel run is handed. A reaction chain that mints more finds the script spent
/// and leaves the command to refuse its missing `run`, as Ruby does with no adapter bound.
pub const POOL: usize = 32;

/// The commands of the domain's aggregates that require a `run`, as the kernel's input
/// `"run_required"` reads them: `["Domain::Aggregate.Command", ...]`. An entity's commands are not
/// minted for.
pub fn run_required_table(domain_ir: &Value) -> Value {
    let domain = domain_ir
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let aggregates = domain_ir
        .get("aggregates")
        .and_then(Value::as_array)
        .into_iter()
        .flatten();
    let verbs = aggregates.flat_map(|aggregate| {
        let name = aggregate
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let commands = aggregate
            .get("commands")
            .and_then(Value::as_array)
            .into_iter()
            .flatten();
        commands
            .filter(|command| requires_run(command))
            .filter_map(|command| command.get("name").and_then(Value::as_str))
            .map(|command| format!("{domain}::{name}.{command}"))
            .collect::<Vec<_>>()
    });
    Value::Array(verbs.map(Value::String).collect())
}

fn requires_run(command: &Value) -> bool {
    command
        .get("attributes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|attribute| {
            attribute.get("name").and_then(Value::as_str) == Some("run")
                && attribute.get("optional").and_then(Value::as_bool) != Some(true)
        })
}

/// The ids `port` hands the kernel for one run: [`POOL`] of them.
pub fn pool(port: &dyn IdentityPort) -> Value {
    Value::Array((0..POOL).map(|_| json!(port.uuid())).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct Counter(Cell<u32>);

    impl IdentityPort for Counter {
        fn uuid(&self) -> String {
            self.0.set(self.0.get() + 1);
            self.0.get().to_string()
        }
    }

    #[test]
    fn only_a_command_with_a_required_run_is_listed() {
        let ir = json!({"name": "D", "aggregates": [{"name": "Check", "commands": [
            {"name": "Start", "attributes": [{"name": "run", "optional": false}]},
            {"name": "Soft", "attributes": [{"name": "run", "optional": true}]},
            {"name": "Other", "attributes": [{"name": "booking"}]}
        ]}]});
        assert_eq!(run_required_table(&ir), json!(["D::Check.Start"]));
    }

    #[test]
    fn the_pool_is_the_port_asked_for_each_id_in_order() {
        let ids = pool(&Counter(Cell::new(0)));
        assert_eq!(
            ids.as_array()
                .map(|a| (a.len(), a[0].clone(), a[1].clone())),
            Some((POOL, json!("1"), json!("2")))
        );
    }
}
