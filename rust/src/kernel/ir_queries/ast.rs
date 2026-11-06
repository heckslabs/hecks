//! An invariant's `ast` node, read from the IR into the shared `Expr`. The same reading the host
//! does over `serde_json` (`rust/host/core/src/expr_json.rs`), over the kernel's own `Json`.

use crate::kernel::{BlockMode, Comparison, Expr, Json, StripSide};
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock, PoisonError};

/// The `'static` spelling of a name, leaked once however often it is read.
fn intern(text: &str) -> &'static str {
    static NAMES: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();
    let mut names = NAMES
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if let Some(known) = names.get(text) {
        return known;
    }
    let leaked: &'static str = Box::leak(text.to_string().into_boxed_str());
    names.insert(leaked);
    leaked
}

/// A node with its tag, for the reads every operator makes.
struct Node<'a> {
    op: &'a str,
    json: &'a Json,
}

impl Node<'_> {
    fn field(&self, name: &str) -> Result<&Json, String> {
        self.json
            .get(name)
            .ok_or_else(|| format!("{} node has no {name:?} field", self.op))
    }

    fn expr(&self, name: &str) -> Result<Expr, String> {
        parse(self.field(name)?)
    }

    fn boxed(&self, name: &str) -> Result<Box<Expr>, String> {
        Ok(Box::new(self.expr(name)?))
    }

    fn string(&self, name: &str) -> Result<String, String> {
        let value = self.field(name)?;
        value
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| format!("{}'s {name:?} isn't a string", self.op))
    }

    fn flag(&self, name: &str) -> Result<bool, String> {
        match self.field(name)? {
            Json::Bool(flag) => Ok(*flag),
            _ => Err(format!("{}'s {name:?} isn't a boolean", self.op)),
        }
    }

    fn path(&self, name: &str) -> Result<Vec<String>, String> {
        let segments = self
            .field(name)?
            .as_array()
            .ok_or_else(|| format!("{}'s {name:?} isn't an array", self.op))?;
        let named = |s: &Json| s.as_str().map(str::to_string);
        segments
            .iter()
            .map(|s| {
                named(s).ok_or_else(|| format!("{}'s {name:?} has a non-string element", self.op))
            })
            .collect()
    }

    fn comparison(&self) -> Result<Comparison, String> {
        let cmp = self.field("cmp")?;
        let flag = |name: &str| match cmp.get(name) {
            Some(Json::Bool(flag)) => Ok(*flag),
            _ => Err(format!("{}'s cmp has no {name}", self.op)),
        };
        Ok(Comparison {
            less_than: flag("less_than")?,
            equal: flag("equal")?,
            negated: flag("negated")?,
        })
    }

    fn pair(&self) -> Result<(Box<Expr>, Box<Expr>), String> {
        Ok((self.boxed("left")?, self.boxed("right")?))
    }

    fn receiver(&self) -> Result<Box<Expr>, String> {
        self.boxed("receiver")
    }
}

fn mode_of(text: &str) -> Result<BlockMode, String> {
    match text {
        "all" => Ok(BlockMode::All),
        "any" => Ok(BlockMode::Any),
        "none" => Ok(BlockMode::None),
        other => Err(format!(
            "block_predicate's mode {other:?} is none of all/any/none"
        )),
    }
}

fn side_of(text: &str) -> Result<StripSide, String> {
    match text {
        "both" => Ok(StripSide::Both),
        "left" => Ok(StripSide::Left),
        "right" => Ok(StripSide::Right),
        other => Err(format!("strip's side {other:?} is none of both/left/right")),
    }
}

/// Parses an invariant's `ast` node into an `Expr`; an unrecognized shape is an `Err`.
pub fn parse(json: &Json) -> Result<Expr, String> {
    let op = json
        .get("op")
        .and_then(Json::as_str)
        .ok_or("an ast node has no string \"op\" field")?;
    let node = Node { op, json };
    match op {
        "or" | "and" | "add" | "sub" | "mul" | "div" => {
            let (left, right) = node.pair()?;
            Ok(match op {
                "or" => Expr::Or(left, right),
                "and" => Expr::And(left, right),
                "add" => Expr::Add(left, right),
                "sub" => Expr::Sub(left, right),
                "mul" => Expr::Mul(left, right),
                _ => Expr::Div(left, right),
            })
        }
        "compare" => {
            let (left, right) = node.pair()?;
            Ok(Expr::Compare {
                op: node.comparison()?,
                left,
                right,
            })
        }
        _ => parse_other(&node),
    }
}

fn parse_other(node: &Node) -> Result<Expr, String> {
    Ok(match node.op {
        "not" => Expr::Not(node.boxed("expr")?),
        "include" => Expr::Include {
            haystack: node.boxed("haystack")?,
            needle: node.boxed("needle")?,
        },
        "int" => Expr::Int(
            node.field("value")?
                .as_i64()
                .ok_or("int's value isn't an integer")?,
        ),
        "float" => Expr::Float(
            node.field("value")?
                .as_f64()
                .ok_or("float's value isn't a number")?,
        ),
        "str" => Expr::Str(node.string("value")?),
        "bool" => Expr::Bool(node.flag("value")?),
        "nil" => Expr::Nil,
        "sign_test" => Expr::SignTest {
            op: node.comparison()?,
            receiver: node.receiver()?,
        },
        "empty" => Expr::Empty(node.receiver()?),
        "to_s" => Expr::ToS(node.receiver()?),
        "size" => Expr::Size(node.receiver()?),
        "first" => Expr::First(node.receiver()?),
        "last" => Expr::Last(node.receiver()?),
        "modulo" => Expr::Modulo {
            receiver: node.receiver()?,
            divisor: node.boxed("divisor")?,
        },
        "lookup" => Expr::Lookup(intern(&node.path("path")?.join("."))),
        "array" => {
            let elements = node
                .field("elements")?
                .as_array()
                .ok_or("array's elements isn't an array")?;
            Expr::Array(elements.iter().map(parse).collect::<Result<Vec<_>, _>>()?)
        }
        _ => return parse_text_operator(node),
    })
}

fn parse_text_operator(node: &Node) -> Result<Expr, String> {
    Ok(match node.op {
        "matches_regex" => Expr::MatchesRegex {
            receiver: node.receiver()?,
            pattern: node.string("pattern")?,
            flags: node.string("flags")?,
        },
        "presence" => Expr::Presence {
            receiver: node.receiver()?,
            negated: node.flag("negated")?,
        },
        "assignment" => Expr::Assignment {
            receiver: node.receiver()?,
            negated: node.flag("negated")?,
        },
        "split" => Expr::Split {
            receiver: node.receiver()?,
            separator: node.string("separator")?,
        },
        "strip" => Expr::Strip {
            receiver: node.receiver()?,
            side: side_of(&node.string("side")?)?,
        },
        "starts_with" => Expr::StartsWith {
            receiver: node.receiver()?,
            substring: node.string("substring")?,
        },
        "ends_with" => Expr::EndsWith {
            receiver: node.receiver()?,
            substring: node.string("substring")?,
        },
        _ => return parse_block_operator(node),
    })
}

fn parse_block_operator(node: &Node) -> Result<Expr, String> {
    let param = || Ok::<_, String>(intern(&node.string("param")?));
    Ok(match node.op {
        "block_predicate" => Expr::BlockPredicate {
            mode: mode_of(&node.string("mode")?)?,
            receiver: node.receiver()?,
            param: param()?,
            predicate: node.boxed("predicate")?,
        },
        "sum" => Expr::Sum {
            receiver: node.receiver()?,
            param: param()?,
            predicate: node.boxed("predicate")?,
        },
        "find" => {
            let segments: Vec<&'static str> =
                node.path("path")?.iter().map(|s| intern(s)).collect();
            Expr::Find {
                receiver: node.receiver()?,
                param: param()?,
                predicate: node.boxed("predicate")?,
                path: Box::leak(segments.into_boxed_slice()),
            }
        }
        other => return Err(format!("unrecognized expression op {other:?}")),
    })
}
