// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum OrderDir { Asc, Desc }

#[derive(Debug, Clone)]
pub struct OrderSpec {
    pub field: String,
    pub dir: OrderDir,
    /// Explicit enum mapping — position in this vec is the sort key.
    /// Values not in the list sort after all listed values.
    pub enum_order: Option<Vec<String>>,
    /// When true, strip a leading alphabetic prefix and sort the
    /// trailing number. Lets `--order ref:numeric_ref` sort i2 < i10
    /// (matches the `int(v.get('ref','i999')[1:])` Python pattern in
    /// inbox.sh).
    pub numeric_ref: bool,
}

impl OrderSpec {
    /// Parse a `--order <field>[:asc|desc|enum=a,b,c]` spec.
    pub fn parse(spec: &str) -> Result<Self, String> {
        let (field, rest) = match spec.find(':') {
            Some(i) => (&spec[..i], Some(&spec[i+1..])),
            None    => (spec, None),
        };
        let field = field.to_string();
        if field.is_empty() {
            return Err(format!("invalid --order spec: {}", spec));
        }
        match rest {
            None => Ok(OrderSpec { field, dir: OrderDir::Asc, enum_order: None, numeric_ref: false }),
            Some("asc")  => Ok(OrderSpec { field, dir: OrderDir::Asc,  enum_order: None, numeric_ref: false }),
            Some("desc") => Ok(OrderSpec { field, dir: OrderDir::Desc, enum_order: None, numeric_ref: false }),
            Some("numeric_ref") => Ok(OrderSpec {
                field, dir: OrderDir::Asc, enum_order: None, numeric_ref: true,
            }),
            Some(e) if e.starts_with("enum=") => {
                let list = e[5..].split(',').map(|s| s.to_string()).collect();
                Ok(OrderSpec { field, dir: OrderDir::Asc, enum_order: Some(list), numeric_ref: false })
            }
            Some(other) => Err(format!("invalid --order modifier: {}", other)),
        }
    }

    fn key(&self, rec: &Record) -> OrderKey {
        let raw = field_to_string(rec.get(&self.field));
        if let Some(list) = &self.enum_order {
            let idx = list.iter().position(|v| v == &raw).unwrap_or(list.len());
            return OrderKey::Int(idx as i64);
        }
        if self.numeric_ref {
            // Strip leading alphabetic chars, parse the tail as int.
            // Missing / unparseable refs get a very large number so they
            // sort last — matches the Python `or 999`.
            let tail: String = raw.chars().skip_while(|c| c.is_alphabetic()).collect();
            return match tail.parse::<i64>() {
                Ok(n) => OrderKey::Int(n),
                Err(_) => OrderKey::Int(i64::MAX),
            };
        }
        if let Ok(n) = raw.parse::<i64>() {
            OrderKey::Int(n)
        } else if let Ok(f) = raw.parse::<f64>() {
            OrderKey::Float(f)
        } else {
            OrderKey::Str(raw)
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum OrderKey { Int(i64), Float(f64), Str(String) }

impl Eq for OrderKey {}
impl PartialOrd for OrderKey { fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(o)) } }
impl Ord for OrderKey {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        match (self, o) {
            (OrderKey::Int(a),   OrderKey::Int(b))   => a.cmp(b),
            (OrderKey::Float(a), OrderKey::Float(b)) => a.partial_cmp(b).unwrap_or(Ordering::Equal),
            (OrderKey::Int(a),   OrderKey::Float(b)) => (*a as f64).partial_cmp(b).unwrap_or(Ordering::Equal),
            (OrderKey::Float(a), OrderKey::Int(b))   => a.partial_cmp(&(*b as f64)).unwrap_or(Ordering::Equal),
            (OrderKey::Str(a),   OrderKey::Str(b))   => a.cmp(b),
            // Mixed types: numeric < string.
            (OrderKey::Int(_),   OrderKey::Str(_))   => Ordering::Less,
            (OrderKey::Float(_), OrderKey::Str(_))   => Ordering::Less,
            (OrderKey::Str(_),   OrderKey::Int(_))   => Ordering::Greater,
            (OrderKey::Str(_),   OrderKey::Float(_)) => Ordering::Greater,
        }
    }
}

/// Order a slice of record refs in place according to the spec. Ties on
/// the primary key break on created_at ascending — stable byte-for-byte
/// output across runs.
pub fn order_records<'a>(recs: Vec<&'a Record>, spec: &OrderSpec) -> Vec<&'a Record> {
    order_records_multi(recs, std::slice::from_ref(spec))
}

/// Multi-key ordering. Each spec applies left-to-right; the first tie
/// breaks on the second, and so on. Final tie-break is created_at ASC.
pub fn order_records_multi<'a>(mut recs: Vec<&'a Record>, specs: &[OrderSpec]) -> Vec<&'a Record> {
    recs.sort_by(|a, b| {
        for spec in specs {
            let ka = spec.key(a);
            let kb = spec.key(b);
            let cmp = ka.cmp(&kb);
            let cmp = if spec.dir == OrderDir::Desc { cmp.reverse() } else { cmp };
            if cmp != std::cmp::Ordering::Equal { return cmp; }
        }
        let ca = field_to_string(a.get("created_at"));
        let cb = field_to_string(b.get("created_at"));
        ca.cmp(&cb)
    });
    recs
}

