//! Which signed-in roles may manage a site's payments: a per-site setting, read once at boot.
//!
//! `HECKS_PAYMENTS_MANAGER_ROLES` is a comma-separated list of exact role names. Unset means
//! `Owner`, which is what the host did before the setting existed. A set value must be a
//! plausible list or the boot is refused; a refusal names the variable and the kind of mistake,
//! never the value. A caller manages payments when their role is in the list, compared exactly:
//! no case folding, no hierarchy, no wildcard.

use std::sync::OnceLock;

/// The variable that names the roles allowed to manage payments.
pub const VARIABLE: &str = "HECKS_PAYMENTS_MANAGER_ROLES";
/// The role that manages payments when the variable is unset.
pub const DEFAULT_ROLE: &str = "Owner";
/// The most roles one list may name.
pub const MAX_ENTRIES: usize = 8;
/// The longest role name, after trimming.
pub const MAX_ENTRY_LENGTH: usize = 32;

/// The roles that manage payments when nothing is configured.
pub fn default_roles() -> Vec<String> {
    vec![DEFAULT_ROLE.to_string()]
}

/// Parses the variable's value; `None` (unset) gives the default list.
pub fn parse(raw: Option<&str>) -> Result<Vec<String>, String> {
    let Some(raw) = raw else { return Ok(default_roles()) };
    let refuse = |why: &str| Err(format!("{VARIABLE} is invalid: {why}"));
    let entries: Vec<&str> = raw.split(',').map(str::trim).collect();
    if entries.len() > MAX_ENTRIES {
        return refuse(&format!("it names more than {MAX_ENTRIES} roles"));
    }
    for (index, entry) in entries.iter().enumerate() {
        let position = index + 1;
        if entry.is_empty() {
            return refuse(&format!("entry {position} is empty; name at least one role and no blank entries"));
        }
        if entry.len() > MAX_ENTRY_LENGTH {
            return refuse(&format!("entry {position} is longer than {MAX_ENTRY_LENGTH} characters"));
        }
        let starts_well = entry.starts_with(|c: char| c.is_ascii_alphanumeric());
        if !starts_well || !entry.chars().all(|c| c.is_ascii_alphanumeric() || c == ' ' || c == '-') {
            return refuse(&format!("entry {position} is not a role name: letters, digits, spaces and hyphens only, starting with a letter or digit"));
        }
    }
    Ok(entries.into_iter().map(String::from).collect())
}

/// Reads the setting into `cell` the first time and never again, whatever the environment
/// does afterwards. `read` stands for the environment lookup.
pub fn read_once(cell: &OnceLock<Result<Vec<String>, String>>, read: impl FnOnce() -> Option<String>) -> &Result<Vec<String>, String> {
    cell.get_or_init(|| parse(read().as_deref()))
}

/// This process's setting, read from the environment on first use (the boot check is the first).
pub fn configured() -> &'static Result<Vec<String>, String> {
    static CELL: OnceLock<Result<Vec<String>, String>> = OnceLock::new();
    read_once(&CELL, || std::env::var(VARIABLE).ok())
}

/// Refuses the boot when this process's setting is invalid.
pub fn check_boot() -> Result<(), String> {
    configured().as_ref().map(|_| ()).map_err(Clone::clone)
}

/// The roles for a request. An invalid setting never gets here (the boot was refused); should it
/// ever, only the default role manages, so a mistake narrows access instead of widening it.
pub fn manager_roles() -> Vec<String> {
    configured().clone().unwrap_or_else(|_| default_roles())
}

/// Whether `role` is one of `roles`, by exact string match.
pub fn manages(roles: &[String], role: &str) -> bool {
    roles.iter().any(|allowed| allowed == role)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roles(raw: Option<&str>) -> Vec<String> {
        parse(raw).unwrap()
    }

    #[test]
    fn unset_means_owner_only() {
        let list = roles(None);
        assert_eq!(list, ["Owner"]);
        assert!(manages(&list, "Owner"));
        assert!(!manages(&list, "Admin"));
        assert!(!manages(&list, "Member"));
    }

    #[test]
    fn a_configured_list_admits_exactly_its_roles() {
        let list = roles(Some("Owner,Admin"));
        assert!(manages(&list, "Owner") && manages(&list, "Admin"));
        assert!(!manages(&list, "Editor"));
        assert!(!manages(&list, ""));
    }

    #[test]
    fn whitespace_is_trimmed_and_case_is_exact() {
        let list = roles(Some("  Owner , Account Admin  "));
        assert_eq!(list, ["Owner", "Account Admin"]);
        let lower = roles(Some("admin"));
        assert!(manages(&lower, "admin"));
        assert!(!manages(&lower, "Admin"), "no case folding");
        assert!(!manages(&roles(Some("Admin")), "admin"));
    }

    #[test]
    fn no_wildcard_and_no_hierarchy() {
        assert!(parse(Some("*")).is_err());
        assert!(!manages(&roles(Some("Admin")), "Owner"), "naming Admin does not admit Owner");
    }

    #[test]
    fn an_invalid_setting_is_refused_naming_the_variable() {
        let too_many = ["Role"; MAX_ENTRIES + 1].join(",");
        let too_long = "A".repeat(MAX_ENTRY_LENGTH + 1);
        for bad in ["", "   ", ",", "Owner,", ",Owner", "Owner,,Admin", "Own/er", "Owner\nAdmin", "Own\u{7}er", "Admin;Owner", "-Admin", "Ad_min", "Régisseur", too_many.as_str(), too_long.as_str()] {
            let message = parse(Some(bad)).expect_err(bad);
            assert!(message.starts_with(VARIABLE), "{message}");
        }
        assert!(parse(Some(&"A".repeat(MAX_ENTRY_LENGTH))).is_ok());
        assert!(parse(Some(&["Role"; MAX_ENTRIES].join(","))).is_ok());
    }

    #[test]
    fn a_refusal_never_echoes_the_value() {
        let message = parse(Some("sk_live_SECRET/value")).unwrap_err();
        assert!(!message.contains("sk_live"), "{message}");
    }

    #[test]
    fn the_setting_is_read_once() {
        let cell = OnceLock::new();
        let reads = std::cell::Cell::new(0);
        let first = read_once(&cell, || {
            reads.set(reads.get() + 1);
            Some("Owner,Admin".to_string())
        });
        assert_eq!(first.as_ref().unwrap(), &["Owner", "Admin"]);
        let second = read_once(&cell, || {
            reads.set(reads.get() + 1);
            Some("Editor".to_string())
        });
        assert_eq!(second.as_ref().unwrap(), &["Owner", "Admin"]);
        assert_eq!(reads.get(), 1);
    }

    #[test]
    fn an_invalid_value_stays_refused_once_read() {
        let cell = OnceLock::new();
        assert!(read_once(&cell, || Some("a/b".to_string())).is_err());
        assert!(read_once(&cell, || None).is_err());
    }
}
