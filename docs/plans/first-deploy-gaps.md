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
