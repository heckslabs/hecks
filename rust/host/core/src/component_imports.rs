// The imports the host grants a component, as the runner links them: the clock, secrets and
// outbound requests of `rust/host/wit`. This file holds the contract and the glue to the wasm
// linker; the adapters that answer (the process's secrets, its outbound client) are outside the
// runtime and arrive as an `Imports` value.

use crate::component_runner::RunState;
use std::sync::Arc;
use wasmtime::component::{HasSelf, Linker};

mod wit {
    wasmtime::component::bindgen!({
        path: "../wit",
        world: "granted",
    });
}

use wit::hecks::adapters::{clock, http_out, secrets};

/// Why an import was not answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The component asked for something its grant does not declare; carries the name asked.
    Undeclared(String),
    /// The grant allows it but the host could not carry it out; carries the reason.
    Failed(String),
}

/// One outbound request a component asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub timeout_ms: u32,
}

/// The answer to a request that reached its host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// What answers a component's `secrets` and `http-out` imports. An implementation checks the
/// component's declared grant and refuses by name what it does not declare.
pub trait Imports: Send + Sync {
    /// The value of the secret `name`, `None` when the host holds none.
    fn secret(&self, name: &str) -> Result<Option<String>, Refusal>;
    /// Makes the request `call` describes.
    fn request(&self, call: Call) -> Result<Reply, Refusal>;
}

/// The grant of a component declared no imports: every ask is refused by name.
pub struct NoGrants;

impl Imports for NoGrants {
    fn secret(&self, name: &str) -> Result<Option<String>, Refusal> {
        Err(Refusal::Undeclared(name.to_string()))
    }

    fn request(&self, call: Call) -> Result<Reply, Refusal> {
        Err(Refusal::Undeclared(call.url))
    }
}

/// Links the clock, secrets and outbound-request imports into `linker`.
pub(crate) fn link(linker: &mut Linker<RunState>) -> anyhow::Result<()> {
    wit::Granted::add_to_linker::<RunState, HasSelf<RunState>>(linker, |state| state)?;
    Ok(())
}

/// The imports a run answers with when none are given.
pub(crate) fn none() -> Arc<dyn Imports> {
    Arc::new(NoGrants)
}

impl clock::Host for RunState {
    fn now_seconds(&mut self) -> i64 {
        crate::clock::unix_now()
    }
}

impl secrets::Host for RunState {
    fn get(&mut self, name: String) -> Result<Option<String>, secrets::Refusal> {
        self.imports.secret(&name).map_err(|refusal| match refusal {
            Refusal::Undeclared(what) => secrets::Refusal::Undeclared(what),
            Refusal::Failed(why) => secrets::Refusal::Failed(why),
        })
    }
}

impl http_out::Host for RunState {
    fn request(&mut self, call: http_out::Call) -> Result<http_out::Reply, http_out::Refusal> {
        let call = Call {
            method: call.method,
            url: call.url,
            headers: call.headers,
            body: call.body,
            timeout_ms: call.timeout_ms,
        };
        match self.imports.request(call) {
            Ok(reply) => Ok(http_out::Reply {
                status: reply.status,
                headers: reply.headers,
                body: reply.body,
            }),
            Err(Refusal::Undeclared(what)) => Err(http_out::Refusal::Undeclared(what)),
            Err(Refusal::Failed(why)) => Err(http_out::Refusal::Failed(why)),
        }
    }
}
