# Clients share one database instance, each in its own database

**Status:** Accepted; phase 1 is built. Date: 2026-10-06. Builds on [ADR 0090](0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) and the `AwsBox` deploy kind.

## Context

An `AwsBox` deploy generates two stacks: a box and a dedicated RDS instance (`rds.yaml`). A second client site would add a second instance, with its own backups, alarms, patching window and monthly cost, for a database that holds a few hundred megabytes. The user wants one RDS instance shared across clients, owned by the platform rather than by any one client.

Three facts about the code today decide the shape:

- The box stack is given the database stack's `DbSecurityGroupId` and admits itself on 5432, and the containers get `DB_HOST`, `DB_NAME` and `DB_SECRET_ARN`. Everything downstream already goes through one secret and one host name.
- That secret is RDS's managed master secret, and the Rust host (`rust/host/src/main.rs`) and the generated CMS boot script both log in as the literal user `postgres`. Sharing the instance with that credential would give every client's containers the master password.
- `restore-to-rds.sh`, `verify-copy.sh` and the `migration` setting already copy and compare a set of schemas between two databases through a bastion, with a source and a destination named separately.

## Decision

1. **One platform-owned instance.** A new stack, generated like `rds.yaml` but not tied to a client, holds every client's database. The platform repo owns its world file. Clients refer to it by stack name.
2. **A database and a login role per client.** Each client gets a database and a role that owns only it. The role is not a superuser and has no rights on another client's database. A client's data therefore dumps, restores and hands over on its own, and one client's bug cannot read another's rows. The era write-fence, which a superuser skips, is in force for it.
3. **A client's world says `shared_database`.** `deployed_to("AwsBox")` gains `shared_database "<stack>"`. With it the generator writes no `rds.yaml`; the Makefile and `deploy-box.sh` read the endpoint and security group from the shared stack; the sizing settings that belong to the instance (`database_class`, `storage_gb`, `engine_version`, `backup_days`) are refused. This is wiring, so it lives in the world (the hecksagon side); the domain's bluebook is unchanged.
4. **The containers read the client's own secret, never the master's.** The secret is named `<stack>/database` and holds `{username, password, host, port, dbname}`. The box's instance role reads that one secret only. The master secret is read by the operator who provisions, from a bastion, never by a box.
5. **`provision-database.sh` is generated for the client.** It creates the role and the database if they are absent, owned by that role, with a generated password of letters and digits only (the host does not percent-decode), and writes the client secret. Run again, it changes nothing; `--rotate` replaces the password. It runs from a machine that can reach the instance, the way `restore-to-rds.sh` does.
6. **The host and the CMS boot script read `username` from the secret**, defaulting to `postgres` so a dedicated instance behaves as before.
7. **Moving a client onto the shared instance is a data copy, not a deploy.** `restore-to-rds.sh` copies the client's schemas into its new database as its own role; `verify-copy.sh` compares them; the cutover is a roll with the new `DB_HOST` and secret. Each step is run by a person, and the cutover is ask-first.

## What a client's world says

```ruby
deployed_to("AwsBox") do
  region "us-east-1"
  containers [{ name: "web", port: 8080 }, { name: "domain", port: 8082 }]
  shared_database "hecks-platform-rds"   # the platform's instance, by stack name
  database_name "acme"                   # this client's database, and the role that owns it
end
```

The generator then writes `provision-database.sh` and a `make provision BASTION=i-... [ROTATE=--rotate]` target,
and no `rds.yaml`. `make stacks` deploys only the box; `deploy-box.sh` finds the secret `acme/database` by name.
`database_class`, `storage_gb`, `engine_version` and `backup_days` with `shared_database` are refused.

## Phases

1. **Client side (this ADR's build):** `shared_database`, `provision-database.sh`, the host and boot-script `username`, specs and docs.
2. **The shared instance's generator (built):** `deployed_to("AwsSharedDatabase")` writes the instance's `rds.yaml`, a Makefile and a README; the platform repo declares the world.
3. **Lifeadelics moves:** rehearse the copy into the shared instance, verify, then cut over. Production; ask first.
4. **Emaho onboards on it** instead of a dedicated instance.

## Consequences

- One instance's cost, backups and alarms cover every client. One instance's maintenance window, restart or failure touches every client; that is the price, and why the instance belongs to the platform.
- A client's `pg_dump` is its own database, which keeps the handoff promise (their data is theirs to take) a single command.
- A noisy client can use the instance's connections and CPU. The alarms are per instance, not per client; per-client limits (role connection limits) are a later addition.
- The first provisioning of a client needs a person with the master secret and a bastion. That stays manual on purpose.
