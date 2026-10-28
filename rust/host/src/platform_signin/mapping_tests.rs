//! The member mapping against a real Postgres, through the same functions the Google sign-in uses.
//!
//! Each test gets a scratch database shaped like the real head views. The one path these tests do
//! not take is the write that links a member (it needs the compiled domain module); the mapping
//! logic around it is covered with a fake store in the handler tests.

use std::path::Path;
use std::sync::Arc;

use crate::store::Store;
use serde_json::{json, Value};
use tokio_postgres::NoTls;

use super::extension::PlatformSignin;
use super::session::{map_member, HostMembers};
use super::wiring_support::*;
use crate::store::journal_sql::LineageConfig;
use crate::lambda_client::NeverInvoker;

fn domain_ir() -> Value {
    json!({
        "name": "Acme",
        "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
        "membership": {"provider": "Acme", "aggregate": "Acme::Member"},
        "identity": {"provider": "Identity", "register": "Identity::Identity.Register", "link": "Identity::ExternalIdentifier.Link", "resolve": "Identity::ExternalIdentifier.ResolvedBy"},
    })
}

async fn scratch(name: &str) -> Store {
    let (admin, conn) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
        .await
        .expect("postgres");
    tokio::spawn(async move {
        let _ = conn.await;
    });
    admin
        .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
        .await
        .unwrap();
    admin
        .batch_execute(&format!("CREATE DATABASE {name}"))
        .await
        .unwrap();
    let (client, conn) = tokio_postgres::connect(&crate::test_pg::conninfo(name), NoTls)
        .await
        .expect("scratch");
    tokio::spawn(async move {
        let _ = conn.await;
    });
    client
        .batch_execute(
            "CREATE TABLE acme_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
             CREATE VIEW acme_member_head AS SELECT id, state FROM acme_member_head_snapshot_1;
             CREATE TABLE acme_external_identifier_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
             CREATE VIEW acme_external_identifier_head AS SELECT id, state FROM acme_external_identifier_head_snapshot_1;",
        )
        .await
        .unwrap();
    Store::postgres(client)
}

async fn member(
    db: &Store,
    email: &str,
    role: Option<&str>,
    identity: Option<&str>,
    disabled: bool,
) {
    let state = json!({
        "name": {"value": "Person"}, "email": {"value": email},
        "role": role.map(|r| json!({"value": r})), "identity_id": identity.map(|i| json!({"value": i})), "disabled": disabled,
    });
    db.lock().await.execute("INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb)", &[&email, &state]).await.unwrap();
}

async fn known_identity(db: &Store, issuer: &str, subject: &str, identity: &str) {
    let state =
        json!({"issuer": {"value": issuer}, "subject": {"value": subject}, "identity": identity});
    let id = format!("{issuer}:{subject}");
    db.lock().await.execute("INSERT INTO acme_external_identifier_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb)", &[&id, &state]).await.unwrap();
}

struct World {
    db: Store,
    ir: Value,
    config: LineageConfig,
}

impl World {
    async fn new(name: &str) -> Self {
        Self {
            db: scratch(name).await,
            ir: domain_ir(),
            config: LineageConfig {
                domain: "Acme".into(),
                era: Some(1),
                mirrored: None,
                seal_every: None,
            },
        }
    }

    fn members(&self) -> HostMembers<'_> {
        HostMembers {
            store: &self.db,
            domain_ir: &self.ir,
            wasm_path: Path::new("unused.wasm"),
            config: &self.config,
            invoker: &NeverInvoker,
        }
    }

    async fn signs_in(&self) -> Option<crate::auth::Session> {
        let doc = vectors();
        let claims = vector_claims(&doc, "valid");
        map_member(&self.members(), &claims).await.unwrap()
    }
}

#[tokio::test]
async fn a_resolved_identity_signs_its_linked_member_in() {
    let world = World::new("hecks_host_signin_resolves").await;
    member(
        &world.db,
        "linked@example.test",
        Some("Admin"),
        Some("identity-1"),
        false,
    )
    .await;
    known_identity(
        &world.db,
        "https://idp.example",
        "idp-subject-0001",
        "identity-1",
    )
    .await;
    let session = world.signs_in().await.expect("signed in");
    assert_eq!(session.email, "linked@example.test");
    assert_eq!(session.role.as_deref(), Some("Admin"));
}

#[tokio::test]
async fn a_member_linked_to_another_identity_is_not_signed_in() {
    let world = World::new("hecks_host_signin_other_identity").await;
    member(
        &world.db,
        "person@example.test",
        Some("Admin"),
        Some("identity-other"),
        false,
    )
    .await;
    assert!(world.signs_in().await.is_none());
}

#[tokio::test]
async fn an_unknown_person_is_not_signed_in() {
    let world = World::new("hecks_host_signin_unknown").await;
    assert!(world.signs_in().await.is_none());
}

#[tokio::test]
async fn a_disabled_member_is_not_signed_in_by_identity_or_by_email() {
    let world = World::new("hecks_host_signin_disabled").await;
    member(&world.db, "person@example.test", Some("Admin"), None, true).await;
    assert!(world.signs_in().await.is_none());
    let linked = World::new("hecks_host_signin_disabled_linked").await;
    member(
        &linked.db,
        "linked@example.test",
        Some("Admin"),
        Some("identity-1"),
        true,
    )
    .await;
    known_identity(
        &linked.db,
        "https://idp.example",
        "idp-subject-0001",
        "identity-1",
    )
    .await;
    assert!(linked.signs_in().await.is_none());
}

#[tokio::test]
async fn a_member_without_a_role_is_not_signed_in() {
    let world = World::new("hecks_host_signin_no_role").await;
    member(
        &world.db,
        "linked@example.test",
        None,
        Some("identity-1"),
        false,
    )
    .await;
    known_identity(
        &world.db,
        "https://idp.example",
        "idp-subject-0001",
        "identity-1",
    )
    .await;
    assert!(world.signs_in().await.is_none());
    let unlinked = World::new("hecks_host_signin_no_role_email").await;
    member(&unlinked.db, "person@example.test", None, None, false).await;
    assert!(unlinked.signs_in().await.is_none());
}

#[tokio::test]
async fn the_whole_callback_over_a_real_store_sets_the_session_and_clears_the_cookie() {
    let world = World::new("hecks_host_signin_whole").await;
    member(
        &world.db,
        "linked@example.test",
        Some("Admin"),
        Some("identity-1"),
        false,
    )
    .await;
    known_identity(
        &world.db,
        "https://idp.example",
        "idp-subject-0001",
        "identity-1",
    )
    .await;
    let doc = vectors();
    let request = request_for(&single(&doc, "valid"));
    let ext = PlatformSignin::new(vector_handler("alongside", Arc::new(Recorder::default())));
    let response = ext.finish(&request, &world.members()).await;
    assert_eq!(response["statusCode"], 302);
    assert_eq!(response["headers"]["location"], "/admin.html");
    assert_eq!(cookies_of(&response).len(), 2);
}

#[tokio::test]
async fn the_whole_callback_over_a_real_store_refuses_an_unlinked_person() {
    let world = World::new("hecks_host_signin_whole_unlinked").await;
    member(
        &world.db,
        "person@example.test",
        Some("Admin"),
        Some("identity-other"),
        false,
    )
    .await;
    let doc = vectors();
    let request = request_for(&single(&doc, "valid"));
    let ext = PlatformSignin::new(vector_handler("alongside", Arc::new(Recorder::default())));
    let response = ext.finish(&request, &world.members()).await;
    assert_eq!(response["statusCode"], 403);
    assert_eq!(cookies_of(&response), vec![super::cookie::clear_header()]);
}
