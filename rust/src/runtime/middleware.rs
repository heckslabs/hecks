//! Middleware — wraps the command dispatch pipeline
//!
//! Each middleware sees the command before and after execution.
//! Used for logging, auth, transactions, metrics, etc.
//!
//! Usage:
//!   rt.use_middleware("logger", |ctx| {
//!       println!("before: {}", ctx.command_name);
//!       ctx.next()?;
//!       println!("after: {:?}", ctx.result);
//!       Ok(())
//!   });

use super::{CommandResult, Value};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct CommandContext {
    pub command_name: String,
    pub attrs: HashMap<String, Value>,
    pub result: Option<CommandResult>,
}

pub type MiddlewareFn = Box<dyn Fn(&CommandContext, Phase)>;

#[derive(Debug, Clone, Copy)]
pub enum Phase {
    Before,
    After,
}

pub struct MiddlewareStack {
    layers: Vec<(String, MiddlewareFn)>,
}

impl MiddlewareStack {
    pub fn new() -> Self {
        MiddlewareStack { layers: vec![] }
    }

    pub fn add<F: Fn(&CommandContext, Phase) + 'static>(&mut self, name: &str, handler: F) {
        self.layers.push((name.to_string(), Box::new(handler)));
    }

    pub fn run_before(&self, ctx: &CommandContext) {
        for (_, handler) in &self.layers {
            handler(ctx, Phase::Before);
        }
    }

    pub fn run_after(&self, ctx: &CommandContext) {
        for (_, handler) in self.layers.iter().rev() {
            handler(ctx, Phase::After);
        }
    }

    pub fn count(&self) -> usize {
        self.layers.len()
    }
}
