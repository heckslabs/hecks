// Connection strings for the Postgres-backed tests.
//
// `tokio_postgres` ignores the `PG*` environment variables that libpq (and the
// `pg` gem the Ruby mint fixtures use) honor, so a server that asks for a
// password would refuse every bare `host=localhost dbname=...` string. These
// helpers read `PGHOST`, `PGUSER` and `PGPASSWORD` the way libpq does, and fall
// back to the bare form (OS user, no password) when they are unset, which is
// what a trust-authenticated CI server expects.

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn host() -> String {
    env("PGHOST").unwrap_or_else(|| "localhost".to_string())
}

fn password_part() -> String {
    env("PGPASSWORD").map(|p| format!(" password={p}")).unwrap_or_default()
}

/// Connection string for the admin role (`PGUSER`, else the OS user) on `dbname`.
pub fn conninfo(dbname: &str) -> String {
    let user = env("PGUSER").map(|u| format!(" user={u}")).unwrap_or_default();
    format!("host={} dbname={dbname}{user}{}", host(), password_part())
}

/// Connection string for a role the test created with [`login_clause`] on `dbname`.
pub fn conninfo_as(dbname: &str, role: &str) -> String {
    format!("host={} dbname={dbname} user={role}{}", host(), password_part())
}

/// The `LOGIN` clause of a `CREATE ROLE` the test later connects as: it carries
/// `PGPASSWORD` as the role's password when one is set, so `conninfo_as` can log in.
pub fn login_clause() -> String {
    match env("PGPASSWORD") {
        Some(p) => format!("LOGIN PASSWORD '{}'", p.replace('\'', "''")),
        None => "LOGIN".to_string(),
    }
}
