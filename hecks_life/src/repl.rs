//! REPL — interactive command dispatch loop
//!
//! Boots a domain runtime and presents a prompt for dispatching
//! commands, querying aggregates, and inspecting events/policies.
//!
//! Usage:
//!   repl::run(rt);

use crate::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::io::{self, Write, BufRead};

pub fn run(mut rt: Runtime) {
    let domain_name = rt.domain.name.clone();

    println!("Hecks Life — {} runtime", domain_name);
    println!("  {} aggregate(s), {} policy(ies)",
        rt.domain.aggregates.len(),
        rt.policy_engine.bindings().len());
    println!();
    println!("Commands: dispatch <Command> key=value ...");
    println!("          find <Aggregate> <id>");
    println!("          all <Aggregate>");
    println!("          events | policies");
    println!("          quit");
    println!();

    let stdin = io::stdin();
    loop {
        print!("{}> ", domain_name);
        io::stdout().flush().unwrap();

        let mut line = String::new();
        if stdin.lock().read_line(&mut line).unwrap() == 0 {
            break;
        }
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        match parts[0] {
            "dispatch" | "d" => handle_dispatch(&mut rt, &parts[1..]),
            "find" | "f" => handle_find(&rt, &parts[1..]),
            "all" | "a" => handle_all(&rt, &parts[1..]),
            "events" | "e" => handle_events(&rt),
            "policies" | "p" => handle_policies(&rt),
            "quit" | "q" => break,
            _ => eprintln!("Unknown: {}", parts[0]),
        }
    }
}

fn handle_dispatch(rt: &mut Runtime, args: &[&str]) {
    if args.is_empty() {
        eprintln!("Usage: dispatch <CommandName> key=value ...");
        return;
    }
    let command_name = args[0];
    let mut attrs = HashMap::new();
    for kv in &args[1..] {
        if let Some(eq) = kv.find('=') {
            let key = &kv[..eq];
            let val = &kv[eq + 1..];
            let value = if let Ok(n) = val.parse::<i64>() {
                Value::Int(n)
            } else if val == "true" || val == "false" {
                Value::Bool(val == "true")
            } else {
                Value::Str(val.to_string())
            };
            attrs.insert(key.to_string(), value);
        }
    }

    match rt.dispatch(command_name, attrs) {
        Ok(result) => {
            println!("  ok: {} #{}", result.aggregate_type, result.aggregate_id);
            if let Some(ref event) = result.event {
                println!("  event: {}", event.name);
            }
        }
        Err(e) => eprintln!("  error: {}", e),
    }
}

fn handle_find(rt: &Runtime, args: &[&str]) {
    if args.len() < 2 {
        eprintln!("Usage: find <Aggregate> <id>");
        return;
    }
    match rt.find(args[0], args[1]) {
        Some(state) => {
            println!("  {} #{}", args[0], state.id);
            for (k, v) in &state.fields {
                println!("    {}: {}", k, v);
            }
        }
        None => eprintln!("  not found"),
    }
}

fn handle_all(rt: &Runtime, args: &[&str]) {
    if args.is_empty() {
        eprintln!("Usage: all <Aggregate>");
        return;
    }
    let items = rt.all(args[0]);
    println!("  {} {} record(s)", items.len(), args[0]);
    for state in items {
        println!("    #{}: {:?}", state.id, state.fields);
    }
}

fn handle_events(rt: &Runtime) {
    let events = rt.event_bus.events();
    if events.is_empty() {
        println!("  no events");
    } else {
        for event in events {
            println!("  {} ({} #{})", event.name, event.aggregate_type, event.aggregate_id);
        }
    }
}

fn handle_policies(rt: &Runtime) {
    let bindings = rt.policy_engine.bindings();
    if bindings.is_empty() {
        println!("  no policies");
    } else {
        for b in bindings {
            println!("  {} : {} -> {}", b.name, b.on_event, b.trigger_command);
        }
    }
}
