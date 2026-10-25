//! The position a cursor query pages by: one opaque token naming the last row's order value and
//! identity, and the rule for which rows follow it. Mirrors Ruby's `Ports::Query::Cursor`, so a
//! token minted by either engine is read by the other.

use super::query_ordering::{self, NullsMode, OrderBy};
use super::{Json, Refusal};
use std::cmp::Ordering;

type Rows = Vec<(String, Json)>;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// The token naming a position: the URL-safe base64 (no padding) of the JSON array `[value, id]`.
pub fn encode(value: &Json, id: &str) -> String {
    let body = Json::Array(vec![value.clone(), Json::Str(id.to_string())]).to_json_string();
    base64_url(body.as_bytes())
}

/// The token for `record`, read off the query's order field (null with no declared order).
pub fn token_for(id: &str, record: &Json, order_by: Option<&OrderBy>) -> String {
    let value = order_by.map_or(Json::Null, |order| {
        query_ordering::order_key(record, order.field)
    });
    encode(&value, id)
}

/// A token read back: the order value (`Json::Null` for a null-keyed row) and the row id.
fn decode(token: &str) -> Result<(Json, String), Refusal> {
    let invalid = || {
        Refusal::TypeMismatch(format!(
            "after {token:?} is not a cursor this query handed out"
        ))
    };
    let bytes = unbase64_url(token).ok_or_else(invalid)?;
    let text = String::from_utf8(bytes).map_err(|_| invalid())?;
    match Json::parse(&text) {
        Ok(Json::Array(items)) => match items.as_slice() {
            [value, Json::Str(id)] => Ok((value.clone(), id.clone())),
            _ => Err(invalid()),
        },
        _ => Err(invalid()),
    }
}

/// The rows that follow the token's position, in the order given; all of them with no token.
pub fn rows_after(
    rows: Rows,
    order_by: Option<&OrderBy>,
    after: Option<&str>,
) -> Result<Rows, Refusal> {
    let Some(token) = after else { return Ok(rows) };
    let (held, held_id) = decode(token)?;
    Ok(rows
        .into_iter()
        .filter(|(id, record)| follows(id, record, order_by, &held, &held_id))
        .collect())
}

/// Splits rows fetched one past the page into the page and the token of the next one.
pub fn split_page(
    mut rows: Rows,
    order_by: Option<&OrderBy>,
    size: usize,
) -> (Rows, Option<String>) {
    if rows.len() <= size || size == 0 {
        rows.truncate(size);
        return (rows, None);
    }
    rows.truncate(size);
    let next = rows
        .last()
        .map(|(id, record)| token_for(id, record, order_by));
    (rows, next)
}

fn follows(
    id: &str,
    record: &Json,
    order_by: Option<&OrderBy>,
    held: &Json,
    held_id: &str,
) -> bool {
    let Some(order) = order_by else {
        return id > held_id;
    };
    let key = query_ordering::order_key(record, order.field);
    sequence(&key, id, held, held_id, order) == Ordering::Greater
}

/// Where a row sits against the position in query order: the order value in its direction, nulls
/// where `nulls` puts them, identity breaking ties in the same direction.
fn sequence(key: &Json, id: &str, held: &Json, held_id: &str, order: &OrderBy) -> Ordering {
    let (key_null, held_null) = (*key == Json::Null, *held == Json::Null);
    if key_null != held_null {
        return if key_null == nulls_first(order) {
            Ordering::Less
        } else {
            Ordering::Greater
        };
    }
    let by_value = if key_null {
        Ordering::Equal
    } else {
        query_ordering::compare_comparable(key, held)
    };
    let forward = by_value.then_with(|| id.cmp(held_id));
    if order.descending {
        forward.reverse()
    } else {
        forward
    }
}

const fn nulls_first(order: &OrderBy) -> bool {
    match order.nulls {
        NullsMode::First => true,
        NullsMode::Last => false,
        NullsMode::Native => !order.descending,
    }
}

fn base64_url(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

fn unbase64_url(text: &str) -> Option<Vec<u8>> {
    let sextets: Option<Vec<u32>> = text
        .trim_end_matches('=')
        .bytes()
        .map(|b| ALPHABET.iter().position(|a| *a == b).map(|p| p as u32))
        .collect();
    let sextets = sextets?;
    let mut out = Vec::new();
    for chunk in sextets.chunks(4) {
        if chunk.len() == 1 {
            return None;
        }
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, s)| acc | (s << (18 - 6 * i)));
        for i in 0..chunk.len() - 1 {
            out.push((n >> (16 - 8 * i)) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order(descending: bool, nulls: NullsMode) -> OrderBy {
        OrderBy {
            field: "rating",
            descending,
            nulls,
        }
    }

    fn row(id: &str, rating: Option<i64>) -> (String, Json) {
        let value = rating.map_or(Json::Null, Json::int);
        (id.to_string(), Json::obj(vec![("rating", value)]))
    }

    fn ids(rows: &Rows) -> Vec<&str> {
        rows.iter().map(|(id, _)| id.as_str()).collect()
    }

    #[test]
    fn a_token_is_ruby_base64_of_the_json_pair() {
        // Ruby: Base64.urlsafe_encode64(JSON.generate([100, "r1"]), padding: false)
        assert_eq!(encode(&Json::int(100), "r1"), "WzEwMCwicjEiXQ");
    }

    #[test]
    fn a_token_reads_back_to_its_value_and_id() {
        let (value, id) = decode(&encode(&Json::Null, "r9")).unwrap();
        assert_eq!((value, id.as_str()), (Json::Null, "r9"));
    }

    #[test]
    fn a_foreign_string_is_refused() {
        assert!(matches!(
            decode("not a cursor!"),
            Err(Refusal::TypeMismatch(_))
        ));
    }

    #[test]
    fn ties_break_by_identity_and_nulls_by_placement() {
        let ordered = order(false, NullsMode::First);
        let rows = vec![
            row("r2", None),
            row("r4", None),
            row("r1", Some(100)),
            row("r3", Some(300)),
            row("r6", Some(300)),
        ];
        let token = encode(&Json::int(300), "r3");
        let after = rows_after(rows, Some(&ordered), Some(&token)).unwrap();
        assert_eq!(ids(&after), vec!["r6"]);
    }

    #[test]
    fn a_null_position_is_followed_by_later_nulls_then_values_when_nulls_lead() {
        let ordered = order(false, NullsMode::First);
        let rows = vec![row("r2", None), row("r4", None), row("r1", Some(100))];
        let after = rows_after(rows, Some(&ordered), Some(&encode(&Json::Null, "r2"))).unwrap();
        assert_eq!(ids(&after), vec!["r4", "r1"]);
    }

    #[test]
    fn descending_reverses_values_and_ties() {
        let ordered = order(true, NullsMode::Native);
        let rows = vec![
            row("r5", Some(500)),
            row("r6", Some(300)),
            row("r3", Some(300)),
            row("r4", None),
        ];
        let after = rows_after(rows, Some(&ordered), Some(&encode(&Json::int(300), "r6"))).unwrap();
        assert_eq!(ids(&after), vec!["r3", "r4"]);
    }

    #[test]
    fn the_last_page_has_no_next_token() {
        let rows = vec![row("r1", Some(1)), row("r2", Some(2))];
        assert_eq!(split_page(rows, None, 2).1, None);
    }

    #[test]
    fn a_full_page_names_its_last_row() {
        let rows = vec![row("r1", Some(1)), row("r2", Some(2)), row("r3", Some(3))];
        let (page, next) = split_page(rows, Some(&order(false, NullsMode::Native)), 2);
        assert_eq!(
            (ids(&page), next),
            (vec!["r1", "r2"], Some(encode(&Json::int(2), "r2")))
        );
    }
}
