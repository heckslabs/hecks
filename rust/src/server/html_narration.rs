//! Narration — English translation of domain events and commands
//!
//! Mirrors the Narration aggregate from DomainNarration bluebook.
//! Converts PascalCase names into readable English prose.
//!
//! Usage:
//!   let text = event_to_english("EntryAdded");
//!   // → "an entry is added"

/// Turn an event name into English: "EntryAdded" → "an entry is added"
pub fn event_to_english(event: &str) -> String {
    let words = split_pascal(event);
    if words.len() < 2 { return words.join(" ").to_lowercase(); }

    let verb = &words[words.len() - 1];
    let subject: String = words[..words.len() - 1].join(" ").to_lowercase();

    let article = if starts_with_vowel(&subject) { "an" } else { "a" };

    let verb_lower = verb.to_lowercase();
    let action = to_passive(&verb_lower);

    format!("{} {} {}", article, subject, action)
}

/// Turn a command name into English: "CalculateTotals" → "calculate totals"
pub fn command_to_english(cmd: &str) -> String {
    split_pascal(cmd).join(" ").to_lowercase()
}

/// Split PascalCase into words, keeping acronyms together.
pub fn split_pascal(name: &str) -> Vec<String> {
    let chars: Vec<char> = name.chars().collect();
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_uppercase() {
            let start = i;
            while i < chars.len() && chars[i].is_uppercase() { i += 1; }
            let run = i - start;
            if run == 1 {
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                cur.push(chars[start]);
                while i < chars.len() && chars[i].is_lowercase() {
                    cur.push(chars[i]); i += 1;
                }
            } else {
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                if i < chars.len() && chars[i].is_lowercase() {
                    words.push(chars[start..i-1].iter().collect());
                    cur.push(chars[i-1]);
                    while i < chars.len() && chars[i].is_lowercase() {
                        cur.push(chars[i]); i += 1;
                    }
                } else {
                    words.push(chars[start..i].iter().collect());
                }
            }
        } else {
            cur.push(chars[i]);
            i += 1;
        }
    }
    if !cur.is_empty() { words.push(cur); }
    words
}

/// Convert a past-tense verb to passive voice.
/// "created" → "is created", "reset" → "is reset"
fn to_passive(verb: &str) -> String {
    format!("is {}", verb)
}

fn starts_with_vowel(s: &str) -> bool {
    s.chars().next().map_or(false, |c| {
        "aeiou".contains(c.to_lowercase().next().unwrap_or(' '))
    })
}
