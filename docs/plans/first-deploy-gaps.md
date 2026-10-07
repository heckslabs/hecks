# First-deploy gaps: steps a person did by hand that the generator should own

Bringing the first managed client site up on a shared database instance needed several hand-written steps. Each one is
a place where a generated file, a verb or a spec should replace a person's judgement. They are listed in the order they
were hit. Done means the generator or a spec covers it.

| # | Step done by hand | Where it belongs | State |
|---|-------------------|------------------|-------|
| 1 | The generated CMS Dockerfile fetched the RDS CA bundle with a plain `ADD`, leaving it root-only for the `node` user | `site_host/dockerfile.rb` (`ADD --chmod=0644`) | Done |
| 2 | The media bucket was a hand-written template | `AwsBox`: when `s3_access` names a bucket, `box.yaml` (or a sibling stack) creates it: private, encrypted, versioned, retained on delete | Open |
| 3 | The site's secrets were created by a hand-written script | A generated `create-secrets.sh` from the world's `secrets`: names, JSON shapes, which are generated and which are read from a vault | Open |
| 4 | A box used as the SSM bastion could not reach the new instance: its egress allowed 5432 only to the old database group | The box stack should allow egress on 5432 to `DbSecurityGroupId`; `provision-database.sh` names the bastion's requirement | Open |
| 5 | The first roll failed because the box pulls every container's image and only two were pushed | `deploy-service.sh` (or a `first_deploy` verb) pushes every container's first image before the first roll | Open |
| 6 | Media storage through S3 adds a column the first schema migration lacked, so the CMS failed on its first query | The generated Payload setup (or a spec) checks that, with S3 storage on, the migrations include the media `_objectkey` column | Open |
| 7 | Importing content needed two SSM tunnels (database, domain port) and secrets read into a process | A generated `import` verb that opens the tunnels, reads secrets in-process, runs the importer | Open |
| 8 | A hand list of pages drove the parity check and left out the static sections and the archive | Generate the path list from the Site chapter's routes plus the static pages (or read the baseline's sitemap), so a page cannot be missed | Open |
| 9 | The certificate for the site's name was validated by hand because the zone is not in Route 53 | A `make cert` that requests the certificate and prints the validation record for any DNS host | Open |
| 10 | The generated `make stacks` did not pass the box stack's `CdnPrefixListId`, so the box admitted no traffic and the CDN answered 504 | `make stacks` passes the CDN's managed prefix list (looked up by name) when the world fronts the box with a CDN | Open |
| 11 | The CDN stack was hand-written and created by hand from a certificate, the origin secret and the box's address | A generated CDN stack and `make cdn` that requests the certificate, reads the origin secret in-process and creates the stack | Open |
| 12 | A site's first administrator: `operation.bootstrap_admin` boots the domain against the production database, and on a running host it blocks installing era functions the host already owns. What worked was the signed signup token posted to the running domain (`bin/host admin`'s first half, without its cookie output) | A generated `make first-admin EMAIL=...` that opens the tunnel and does the signup, never booting a second copy of the domain against production | Open |
| 13 | The content parity check and the smoke check were hand-written per site, and each assumed things the live site did not have | Generate both from the Site chapter's routes (every page, in text and markup), with the baseline as an argument | Open |
| 14 | Copying a site's data into its own database as the client role is refused by the era write-fence (row-level security); it had to be restored as the master and then every object handed to the client role by hand | `restore-to-rds.sh` restores as the master and takes `CLIENT_ROLE`, reassigning the schemas' objects to it, then `verify-copy.sh` and a fence check as that role | Open |
| 15 | `render-compose.sh` leaves `DB_NAME` as the task definition has it, so a box on the shared instance asks for the old database | In shared mode set `DB_NAME` from the world's `database_name` (and the same for the preview/rehearsal flows) | Open |
| 16 | A rehearsal box's loopback listener has a self-signed certificate and the CMS's `SITE_URL` is the real hostname, so the browser smoke cannot pass its live-preview checks there | The smoke takes `SMOKE_INSECURE=1` (ignore certificate errors) and `SMOKE_SKIP=live-preview` for a rehearsal, or the rehearsal sets `SITE_URL` to its own origin | Open |
| 17 | Nothing stops a rehearsal copy from running a scheduled send | The rehearsal runbook (and `make rehearse`) checks the copy's queued jobs and refuses, or disables the jobs runner, before the box rolls | Open |

