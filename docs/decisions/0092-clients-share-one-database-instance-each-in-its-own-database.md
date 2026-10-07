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
3. **Lifeadelics moves (done 2026-10-07):** rehearsed twice, then cut over: snapshot, a pre-copy, a write freeze (about ten minutes of downtime in all), a final copy as the master, ownership handed to the client role, the box's secret access pointed at the new secret, a roll, and the site's full smoke (120 checks) and inbox canary on the real hostname.
4. **Emaho onboards on it** instead of a dedicated instance.

## Consequences

- One instance's cost, backups and alarms cover every client. One instance's maintenance window, restart or failure touches every client; that is the price, and why the instance belongs to the platform.
- A client's `pg_dump` is its own database, which keeps the handoff promise (their data is theirs to take) a single command.
- A noisy client can use the instance's connections and CPU. The alarms are per instance, not per client; per-client limits (role connection limits) are a later addition.
- The first provisioning of a client needs a person with the master secret and a bastion. That stays manual on purpose.

## Rehearsal findings

A rehearsal copy of a real site's data into its own database on the shared instance (2026-10-07) changed step 7:

- **Copying as the client's own role fails.** The journal tables carry row-level security (the era write-fence), forced for their owner, so `pg_restore` as the client role is refused ("query would be affected by row-level security policy"). The restore runs as the instance's master, which bypasses the fence.
- **Then the client role takes ownership.** After the restore, the schemas and every table, view, materialized view, standalone sequence and function in them are altered to the client role (a sequence owned by a table follows the table). The master is made a member of the client role for this step. The result: nothing is owned by the master, the role is neither superuser nor `BYPASSRLS`.
- **The fence then holds for the client role.** A write in an earlier era is refused by the policy; a write in the current era is accepted; the journal reads back. `verify-copy.sh` compared 243 tables with identical rows and structure.
- Leftover SSM tunnels from earlier runs hold the scripts' fixed local ports and make a later run fail with a password or `pg_hba` error that looks unrelated; close them first.

`restore-to-rds.sh` takes the master secret as the target and a `CLIENT_ROLE` to hand ownership to; that change is in `docs/plans/first-deploy-gaps.md` (row 14).

### The box rehearsal

A throwaway box (`Rehearsal=true`, no public address) rolled against the rehearsal database as the non-superuser client role, with images built from the current release:

- **Boot as the client role works** once the images are current: the CMS boot and the domain host read `username` and `port` from the secret. The images a site runs before the move log in as `postgres`, so they must be rebuilt first (a prerequisite of the move, as written above). The domain resolved its era as "use existing" (ten held eras, current era 10): the move mints no era.
- **The site's own smoke passed 109 checks** against the box (public pages, blog, admin through the account token, the CMS driving the domain, the era check, sign-in refusals). The 11 that failed were the live-preview checks: the CMS's `SITE_URL` is the production hostname, so a preview iframe loaded from a loopback address is cross-origin. That is a limit of rehearsing without the real hostname.
- **`render-compose.sh` replaces `DB_HOST` and `DB_SECRET_ARN` but not `DB_NAME`**: the task definition still names the old database, so the rehearsal patched it by hand.
- The scheduled-send job (cron every minute in the CMS) runs on a copy too; the copy held no scheduled send, which is worth checking before every rehearsal, because a copy that holds one would mail real subscribers.

### The production move

- The copy took about five minutes; the whole freeze, from stopping the app to the first served page, about ten.
- The old instance and its stack were left untouched, with a manual snapshot taken before the freeze, as the rollback: set the box stack's `DbSecretArn` back to the old secret and roll the box with the old scripts and images.
- The world now says `shared_database`; the generated deploy scripts read the shared stack and the site's secret. **Until it did, a routine deploy would have pointed the site back at the old database.**
- **The egress rule is now owned by the box stack.** The box that served as the SSM bastion also ran the site, and a hand-added outbound rule was the only thing letting it reach the shared instance (its own stack update would have removed it). It was codified the same day without downtime: temporary CIDR rules (which cannot duplicate a group rule), then the shared stack's bastion setting emptied and the box stack's `DbSecurityGroupId` pointed at the shared group, then the temporary rules removed. A site's box that is also the bastion must not be named as the shared stack's bastion: its own ingress rule would duplicate it.
