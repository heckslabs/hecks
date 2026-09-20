require_relative "../../projector"
require_relative "shared"

module Hecks
  module Projections
    module Deploy
      # The AWS Lambda deploy target — docs/decisions/0018-rehydrate-replay-lambda-host.md.
      # An export (`Projector::Target#projects_as`'s own `needs_world: true`),
      # not an ordinary projection: it reads a domain's own
      # `deployed_to("AwsLambda")` `.world` settings, not only its
      # declaration, because a running system has to know how it is wired.
      #
      # `bin/project_deploy` finds and boots the domain's own chapter and
      # its `.world`/`.hecksagon` bindings, calls this through
      # `Projector.call(:aws_lambda, bluebook:, options:, world:)`, and
      # writes the returned tree — see that script for the CLI-facing parts
      # (ARGV parsing, `--tenant`/`--schema`, finding the `.world` file) this
      # target never needs to know about.
      #
      # ## What this generates
      #
      # The SAM template and build Makefile for `rust/host` (the
      # wasmtime+Postgres Lambda entry point) from a domain's own `.world`
      # file, the same way `bin/project_wasm` generates the `.wasm` artifact
      # from the domain's own `.bluebook` — no hand-authored deployment
      # config for any given domain, only a generator run against whatever it
      # declares:
      #
      #   deployed_to("AwsLambda") { region "..."; memory 512; timeout 10 }
      #
      # is a verb in a domain's `.world` file, read through `Hecks.world`'s
      # own generic settings bag
      # (`lib/hecks/bluebook/dsl/world_builder.rb#method_missing`).
      #
      # Self-contained: the returned `template.yaml` owns its own private
      # VPC, subnets, and RDS Postgres instance, not just the Lambda — no
      # externally-supplied database, no secret anyone has to type (RDS's
      # own `ManageMasterUserPassword` plus a CloudFormation dynamic
      # reference compose `DATABASE_URL` at deploy time). `PackageType:
      # Zip`, `Runtime: provided.al2023` — no container, no Docker, no ECR.
      #
      # `Shared` (`lib/hecks/projections/deploy/shared.rb`) carries the parts
      # of this generator `Fargate` needs too — VPC/subnet/security-group
      # resources, RDS/Aurora, `bastion.yaml`, and the era-minting/
      # translation Make recipes — plain functions, not a registered target
      # of their own.
      module Lambda
        extend Projector::Target

        projects_as :aws_lambda, needs_world: true, emits: :files

        module_function

        # Generates `template.yaml`, `Makefile`, `samconfig.toml`, and
        # (unless this domain borrows another domain's RDS instance)
        # `bastion.yaml` for one domain's `deployed_to("AwsLambda")` deploy
        # target.
        #
        # `bluebook:` establishes admission — a real chapter, not merely a
        # directory — but generation itself reads from `options`: every
        # loaded chapter (`options[:cross_domain_registry]`), not only this
        # one, is what a cross-domain policy's own invoke grant needs.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options
        # @option options [Bluebook::World] :world the domain's `.world` settings,
        #   required — `Projector.call`'s own `world:` keyword merges this in
        # @option options [String] :domain_dir the domain directory's path
        # @option options [String] :root the hecks project root, for `rust/host`,
        #   `rust/dist`, and this project's own `Gemfile.lock`
        # @option options [String] :world_file the `.world` file's own path, quoted in
        #   refusal messages
        # @option options [Runtime::Registry] :cross_domain_registry every chapter this
        #   domain loads (its own, plus any framework attachments), for resolving
        #   cross-domain policy invoke targets
        # @option options [Hash] :tenant `--tenant`/`--schema` overrides
        #   (`{tenant: "acme", schema: "acme"}`), or omitted for an ordinary deploy
        # @return [Hash{String => String}] `"template.yaml"`, `"Makefile"`,
        #   `"samconfig.toml"`, and — unless this domain declares `database "Shared"` —
        #   `"bastion.yaml"`, each mapped to its rendered content
        # @raise [ArgumentError] if the domain's own deploy settings conflict (both
        #   `web "Rust"` and a `lambda_handler.rb`, `database "Shared"` with no
        #   `owner`, and the other refusals `deploy.bluebook`'s own
        #   `LambdaTarget.Declare` and this generator raise)
        def call(bluebook:, options: {})
          world                 = options.fetch(:world)
          domain                = options.fetch(:domain_dir)
          root                  = options.fetch(:root)
          world_file            = options.fetch(:world_file)
          cross_domain_registry = options.fetch(:cross_domain_registry)
          tenant_options        = options[:tenant] || {}

          domain_name          = File.basename(domain)
          declared_domain_name = world.domain

          deploy_settings = world.for_verb("deployed_to")

          # **`PII` detection** — structural only, no live boot: `load_bluebooks`/a
          # bare `.hecksagon` `Kernel.load` populate `registry.pending_privacy_
          # markings` (`AggregateDoor#mark_sensitive`/`BindingProxy#mark_sensitive`,
          # lib/hecks/runtime/registry.rb) the same way `Runtime::Loader.boot`'s
          # own first phase does, without that method's later `run_boot_gates!`/
          # `dispatcher_for` steps — those need a live persistence adapter (a real
          # Postgres connection for a PostgresEra-bound domain), which a static
          # template generator must never require. A registry of its own, not
          # `cross_domain_registry` — that one boots this domain's bluebook too,
          # but through a different, hand-rolled port/adapter load (persistence
          # + extraction + memory + prism only) than the one `pending_privacy_
          # markings` was verified against; kept separate rather than assumed
          # equivalent.
          pii_registry = Hecks::Runtime::Registry.new(root: File.expand_path(domain))
          Hecks.with_registry(pii_registry) do
            bootstrap = Hecks::Ports::Loading.bootstrap
            bluebook_dir = File.join(domain, "bluebook")
            bootstrap.load_library
            bootstrap.load_project(bootstrap.shared_root(nil, bluebook_dir))
            bootstrap.load_bluebooks(bluebook_dir)
            Dir.glob(File.join(bluebook_dir, "*.hecksagon")).each { |file| Kernel.load(file) }
          end

          # Only `category: "pii"` counts — `phi` or any other vocabulary a
          # consuming domain's own `mark_sensitive` calls use stays a Governance/
          # redaction concern (Privacy::Marking's own mechanism) without also
          # provisioning CloudFront/WAF, which this generator has no way to know
          # is warranted for, say, health data under a different compliance
          # regime entirely. A domain wanting the same protection for a
          # non-"pii" category marks it "pii" too — the category string is
          # open-ended by design (privacy.bluebook's own header), not a closed
          # enum this generator could instead enumerate.
          pii_detected = pii_registry.pending_privacy_markings.any? { |marking| marking[:category].to_s == "pii" }

          # **The tenant override itself** — see this file's own header comment on
          # `--tenant`/`--schema` for the full reasoning. Applied here, before
          # `infra_name`/`hecks_schema` are computed below, so both read it the
          # same way they already read any other `deployed_to` setting.
          if tenant_options[:tenant]
            base_stack_name = deploy_settings[:stack_name] || domain_name
            deploy_settings = deploy_settings.merge(
              stack_name: "#{base_stack_name}-#{tenant_options[:tenant]}",
              schema:     tenant_options[:schema] || tenant_options[:tenant]
            )
          end

          # **Every AWS-facing name below** — stack, Lambda logical id (and so the
          # RDS logical id derived from it, `#{logical_id}Db`), S3 prefixes,
          # bastion/secret names — reads this, not `domain_name`, from here on.
          # Ordinarily they're the same string, and most domains never set
          # `stack_name` at all. They diverge on purpose for a domain whose
          # declared identity (`Hecks.bluebook`, hence `world.domain`, hence
          # `.world`'s own filename — `domain_name` above, needed just to find
          # that file) no longer matches its live AWS stack's own name: a
          # CloudFormation stack cannot be renamed in place, and this domain's
          # logical ids are already load-bearing on a real RDS instance other
          # domains borrow from in Shared mode (see `owner_stack_name` below) —
          # regenerating the template under a new stack/logical-id would not
          # rename anything, it would stand up a second, empty, disconnected
          # set of AWS resources next to the real one. `stack_name
          # "embryonaut"` in `deployed_to("AwsLambda")` pins the original name
          # forever, independent of any later `formerly_known_as`-style rename
          # to the domain's own declared identity.
          infra_name = deploy_settings[:stack_name] || domain_name

          # **The actual Postgres/RDS identifier** — every domain before this one
          # ever picked a single-word `stack_name` (or none at all, falling back
          # to a single-word directory `domain_name`), so `infra_name` itself was
          # already a valid database name and nothing ever needed a second
          # variable. `stack_name "quality-control-webhook"` (a real, live,
          # multi-word choice — the first one) broke that assumption for real:
          # RDS's own DBName/DatabaseName parameter refuses it outright
          # ("DBName must begin with a letter and contain only alphanumeric
          # characters" — confirmed live, a genuine CREATE_FAILED before this
          # existed), and `infra_name` unsanitized is also what every downstream
          # consumer (WebFunction/#{logical_id}'s own DB_NAME Environment
          # variable, every Makefile shell command that connects `-d
          # #{infra_name}`) reads as the database to actually connect to — so
          # every one of those has to agree on the same sanitized spelling, not
          # just the one CloudFormation property that happened to refuse loudly.
          # Stack names, logical ids, and S3 prefixes are unchanged (still read
          # `infra_name` directly) — CloudFormation/S3 both allow hyphens fine;
          # only the actual database identifier needed this at all.
          db_name = infra_name.gsub(/[^a-zA-Z0-9]/, "")

          # Validated, not hand-checked — dispatches into lib/hecks/deploy's
          # own LambdaTarget.Declare (the same given/invariant machinery every
          # other kind of bluebook mistake in this codebase is caught by),
          # replacing a `fetch(:region) { abort ... }` chain with
          # real, named, corpus-testable refusals: memory/timeout are actual
          # Integers here (never silently stringified) and checked against
          # Lambda's own real 128-10240 MB / 900s ceilings, not just "present or
          # not." Only the default values stay Ruby's own concern —
          # deploy.bluebook's own header explains why: a command-level `default:`
          # is honored only at the JSON/Rust-codegen boundary, never by Ruby's
          # own direct dispatch — so this validates a fully-resolved target,
          # after defaulting, not instead of it.
          deploy_dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          begin
            target = deploy_dispatcher.dispatch(
              "Deploy::LambdaTarget.Declare",
              with: {
                domain:   { value: declared_domain_name },
                region:   { value: deploy_settings[:region] },
                memory:   { value: deploy_settings.fetch(:memory, 512) },
                timeout:  { value: deploy_settings.fetch(:timeout, 10) },
                # "Postgres" — Embryonaut's own live choice, and every domain
                # declared before this setting existed — unless a domain's own
                # deployed_to("AwsLambda") names "Aurora" explicitly.
                database: { value: deploy_settings.fetch(:database, "Postgres") },
                # "None" — every domain declared before this setting existed,
                # Embryonaut included (its own public web UI is the separate,
                # pre-existing lambda_handler.rb-file-presence mechanism, not this
                # attribute) — unless a domain names "Rust" explicitly.
                web: { value: deploy_settings.fetch(:web, "None") }
              }
            ).instance
          rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsLambda\") is invalid: #{e.message}"
          end

          # `dispatch "None"` / `secret_env "..."` — deploy-time wiring facts, not
          # business invariants `Deploy::LambdaTarget.Declare` itself needs to
          # hold, read straight off `deploy_settings` the same way `owner`/
          # `owner_stack`/`schema`/`stack_name` already are (this file's own
          # comment on `infra_name`, above, has the full reasoning for why those
          # stay Ruby-level rather than validated attributes).
          #
          # `dispatch "None"` decides whether the primary rust/host dispatch
          # Lambda (`#{logical_id}`, computed further below) gets generated at
          # all. Default (unset, every domain declared
          # before this setting existed) keeps generating the rust/host wasmtime
          # dispatch Lambda exactly as always — "None" is the new, opt-in case: no
          # rust/host dispatch Lambda for this domain at all, because a domain
          # with no `.bluebook`-shaped command surface of its own to dispatch
          # through (QualityControl's own real first user: a driving GitHub
          # webhook adapter, `lib/hecks/adapters/driving/github_webhook.rb`,
          # calling straight into `QualityControl::Clearance` through Ruby, never
          # through rust/host's wasmtime dispatch at all) has nothing for that
          # Lambda to ever serve. Reuses the existing `lambda_handler.rb`-file-
          # presence WebFunction mechanism wholesale (Runtime: ruby3.2, Function
          # URL AuthType `NONE`, container build + patch-pg-native for `pg`'s native
          # extension) rather than inventing a second Ruby-Lambda shape — the
          # WebFunction path already proved itself for real (Embryonaut's own live
          # stack) before this ever needed a second consumer; deploy.bluebook's
          # own generator, "one generator reads what a domain declares," extends
          # rather than forks.
          dispatch_none = deploy_settings[:dispatch].to_s == "None"

          # `secret_env "GITHUB_WEBHOOK_SECRET"` — names the env var
          # WebFunction's own `lambda_handler.rb` should find the fetched secret's
          # real plaintext under, once it resolves `#{secret_env}_ARN` (below,
          # WebFunction's own Environment) via the AWS SDK the same cold-start
          # pattern DATABASE_URL/SESSION_SECRET/GOOGLE_CLIENT_ID already use
          # (WebFunction's own header comment: "fetch at runtime, over the SDK,
          # never let CloudFormation/Lambda configuration see it at all"). Wired
          # generically — any WebFunction-shaped domain declaring one gets its own
          # auto-generated, never-typed-or-seen SecretsManager secret + least-
          # privilege grant, not something specific to GitHub webhooks; this
          # domain's own `qa/lambda_handler.rb` is simply the first real consumer.
          webhook_secret_env = deploy_settings[:secret_env]

          # `handler_module "QaWebhookLambdaHandler"` — the same name
          # `lambda_handler.rb`'s own module actually defines, named here rather
          # than assumed, since `dispatch "None"` is a generic mechanism (any
          # future domain could adopt it, each with its own wrapper module name)
          # — "WebLambdaHandler" stays the fixed, historical default for every
          # domain that has never set this (Embryonaut's own, unchanged).
          webhook_handler_module = deploy_settings.fetch(:handler_module, "WebLambdaHandler")
          if dispatch_none && !deploy_settings.key?(:handler_module)
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsLambda\") declares dispatch \"None\" but no handler_module — add handler_module \"YourModuleName\" naming the module #{domain}/lambda_handler.rb defines."
          end

          # Every policy in every loaded chapter, not just the target domain's
          # own top-level list — `uses_framework` (Compliance's own header:
          # "genuinely supports either mode") could in principle attach a chapter
          # that itself declares a cross-domain policy, and a policy nested inside
          # `aggregate "X" do ... end` is exactly as real a cross-domain trigger as
          # one declared at the bluebook's own top level (docs/implemented/guides/policies-
          # and-process-managers.md: "A policy does not care where it was
          # written"). `to_h`'s own `policies` already flattens aggregate-scoped
          # and top-level policies into one list per bluebook — read the same way
          # `rust/project/reactions.rb`'s `emit_cross_domain_policy_table` does.
          cross_domain_lambda_targets = cross_domain_registry.bluebooks.flat_map { |chapter_name, bluebook|
            bluebook.policies.select(&:target_domain).map(&:target_domain)
          }.uniq.sort


          region   = target.state[:region].value
          memory   = target.state[:memory].value
          timeout  = target.state[:timeout].value
          database = target.state[:database].value
          aurora   = database == "Aurora"
          shared   = database == "Shared"
          rust_web = target.state[:web].value == "Rust"

          # **`WAFv2` for CloudFront needs us-east-1** — not a preference, a hard
          # AWS API constraint (`AWS::WAFv2::WebACL` with `Scope: CLOUDFRONT` is
          # refused by CloudFormation outside us-east-1, independent of which
          # region the distribution itself, being global, would otherwise
          # suggest). Refused here, before writing a single file, the same
          # discipline this generator already holds every other one of its own
          # refusals to — a generated template that would only fail at deploy
          # time, in a region a caller may not think to suspect, is a worse
          # failure mode than refusing now with the fix named.
          if pii_detected && region != "us-east-1"
            raise ArgumentError, "#{world_file} marks a field \"pii\" but deployed_to(\"AwsLambda\") sets region " \
                                  "#{region.inspect} — a CloudFront-scoped WAFv2 WebACL can only be created in " \
                                  "us-east-1. Set region \"us-east-1\", or remove the pii marking if this domain " \
                                  "genuinely holds none."
          end

          # Read straight off `deploy_settings` (the raw `WorldBuilder` bag), not
          # through `target` — these two are optional and pii-only, unlike every
          # `target.state[...]` field above, which `LambdaTarget` validates as
          # always-present for every `AwsLambda` deployment regardless of pii.
          # "none" (`RestrictionType: none`, `Locations: []`) is CloudFront's own
          # default shape for "no restriction configured" — declaring one later
          # is a `deployed_to` edit, not a template rewrite.
          geo_restriction_type      = deploy_settings[:geo_restriction] || "none"
          geo_restriction_countries = deploy_settings[:geo_restriction_countries] || []

          # **The storehouse** — this domain provisions no RDS/VPC of its own at all;
          # it borrows another already-deployed domain's instance instead,
          # isolated by a native Postgres schema (this domain's own lowercase
          # name) rather than a separate database. `owner` is read the same way
          # `pg_version`/`google_oauth_present` below are — a Ruby-level fact off
          # `deploy_settings` directly, not one of `Deploy::LambdaTarget.Declare`'s
          # own validated attributes (deploy.bluebook's own comment on why: which
          # domain owns the shared instance is a deploy-time wiring fact, not a
          # business invariant).
          if shared
            owner_domain_name = deploy_settings[:owner] or raise ArgumentError, <<~MSG
              #{world_file}'s deployed_to("AwsLambda") declares database "Shared" but no owner. Add one, e.g.:

                  deployed_to("AwsLambda") do
                    ...
                    database "Shared"
                    owner "Embryonaut"
                  end

              naming the already-deployed domain whose Postgres instance this one borrows.
            MSG
            # `hecks-<lowercase name>` / lowercase name-as-dbname — the same
            # two conventions `stack_name`/`DBName: #{infra_name}` below already
            # commit to for this domain, and the default for the owner too. Not
            # always the owner's real stack name, though — a domain generated
            # before this convention existed keeps whatever it was actually
            # deployed as (real, live example: Embryonaut's own stack is
            # "hecksagain-embryonaut", a legacy prefix, not "hecks-embryonaut" --
            # `deploy:`'s own owner-outputs lookup below would look for a stack
            # that has never existed and fail before this domain's own `sam
            # deploy` ever ran). `owner_stack "hecksagain-embryonaut"` is the
            # escape hatch, read the same deploy_settings-direct way `owner`
            # itself is (deploy.bluebook's own comment on why neither lives in
            # the validated LambdaTarget aggregate) — optional, defaults to the
            # ordinary convention for every domain that doesn't need it.
            owner_stack_name = deploy_settings[:owner_stack] || "hecks-#{owner_domain_name.downcase}"
            owner_db_name     = owner_domain_name.downcase
          end

          # `HECKS_SCHEMA` — rust/host's own optional counterpart to Ruby's
          # `settings[:schema]` (postgres.rb's own `connect_for`). Automatic for a
          # Shared-mode domain (this domain's own lowercase name — matches the
          # schema the real migration creates for it, `CREATE SCHEMA
          # #{infra_name}`, and needs no separate declaration since Shared mode
          # already implies it). Optional and explicit otherwise
          # (`deployed_to("AwsLambda") { schema "embryonaut" }`) — for an owning
          # domain that later migrates itself onto a shared instance's own schema
          # too (Embryonaut, in the real migration this exists for), without
          # switching its own `database` setting away from where its real RDS
          # instance already lives.
          hecks_schema = shared ? infra_name : deploy_settings[:schema]

          logical_id = "#{infra_name.split(/[_-]/).map(&:capitalize).join}Function"
          # `stack_prefix` — the "hecks-" half of this domain's own stack name, a
          # setting only for a domain whose live stack predates the convention
          # (real, live example: Embryonaut's own stack, both its Lambda function
          # names, and its Google OAuth secret are all "hecksagain-embryonaut*",
          # generated by the pre-rename hecksagain fork). Same shape and
          # reasoning as `owner_stack` above — read `deploy_settings`-direct, not
          # validated by LambdaTarget, optional — but for this domain rather than
          # the owner it borrows from. Everything downstream (stack, FunctionName
          # for both Lambdas, the OAuth secret name and its IAM policy, the
          # bastion stack, samconfig's stack_name/s3_prefix) reads `stack_name`,
          # so one setting moves them all together; `infra_name` (logical ids,
          # deploy/<dir>, DB name) is untouched — that is `stack_name`'s job.
          # Defaults to "hecks", so every domain that doesn't set it regenerates
          # byte-identically.
          stack_prefix = deploy_settings[:stack_prefix] || "hecks"
          stack_name = "#{stack_prefix}-#{infra_name}"

          db_id = "#{logical_id.sub(/Function\z/, '')}Db"
          # The Aurora shape splits the database in two (a DBCluster carrying
          # the managed password/endpoint, plus at least one DBInstance inside
          # it) — every `.Endpoint.Address`/`.MasterUserSecret.SecretArn`
          # reference below has to point at the cluster, not `db_id` itself,
          # when Aurora is chosen. The plain-RDS path is unaffected: `db_ref_id`
          # equals `db_id` exactly, so every one of those references renders
          # byte-identical to before this existed.
          db_ref_id = aurora ? "#{db_id}Cluster" : db_id

          # The Aurora path uses a self-managed secret (`#{db_id}Secret`, below —
          # see its own comment for why: ManageMasterUserPassword's rotation
          # breaks a Lambda's static Environment), not the plain-RDS path's own
          # `db_ref_id.MasterUserSecret` attribute (which only exists for the
          # managed-password feature at all). `secret_sub` is the identifier for
          # use inside a `!Sub` "${...}" interpolation (dot-free for a plain
          # `!Ref`, dotted for a `!GetAtt` attribute — CloudFormation's `${}`
          # auto-detects either shape); `secret_intrinsic` is the same fact
          # spelled as a bare YAML value, for the one site (stack_outputs) that
          # isn't inside a `!Sub` string at all.
          secret_sub       = aurora ? "#{db_id}Secret" : "#{db_ref_id}.MasterUserSecret.SecretArn"
          secret_intrinsic = aurora ? "!Ref #{db_id}Secret" : "!GetAtt #{db_ref_id}.MasterUserSecret.SecretArn"
          # The same `${...}`-inside-`!Sub` identifier `secret_sub` above already
          # is -- used here for #{logical_id}'s own runtime IAM grant instead of a
          # deploy-time `{{resolve:secretsmanager:...}}` dynamic reference (see
          # that Environment.Variables comment below for why DATABASE_URL moved
          # off that mechanism entirely). Shared mode has no `secret_sub` of its
          # own to reach for -- `OwningDatabaseSecretArn` (this template's own
          # Parameter, filled from the owning stack's Output) already is the bare
          # ARN string, not a Ref/GetAtt target inside this stack.
          db_secret_ref = shared ? "OwningDatabaseSecretArn" : secret_sub

          # **Opt-in, by file presence** — a domain that wants its own web app on
          # Lambda too (not every domain has one; Banking doesn't) drops a
          # `lambda_handler.rb` at its own root, the Rack-to-Function-URL-event
          # adapter Sinatra runs through. No new .world verb for this: the file
          # itself is the declaration, the same way a `.hecksagon` file's mere
          # existence is what makes a domain framework-attached.
          web_handler_present = File.exist?(File.join(domain, "lambda_handler.rb"))

          # A domain declares one web story, not both — `web "Rust"` (rust/host
          # serves its own web UI in-process) and a `lambda_handler.rb` (a
          # separate Ruby WebFunction) are two different mechanisms for the same
          # job; picking one silently when both are present would be exactly the
          # kind of ambiguity this generator's own `deploy.bluebook` gate exists
          # to refuse instead of guess at.
          if rust_web && web_handler_present
            raise ArgumentError, "#{domain} declares both web \"Rust\" (#{world_file}) and a lambda_handler.rb (#{File.join(domain, 'lambda_handler.rb')}) — pick one."
          end

          # Read straight out of the domain's own Gemfile.lock, not hardcoded —
          # `patch-pg-native`'s build recipe below has to fetch the same pg
          # version Bundler resolved, or its from-source extension and the
          # gem's own Ruby wrapper (lib/pg.rb, autoloads, etc.) can drift apart.
          # The plain, platform-less lock line ("pg (1.6.3)") is what this
          # matches — platform-suffixed siblings ("pg (1.6.3-aarch64-linux)")
          # fail the all-digits-and-dots capture on purpose.
          #
          # Optional, not required whenever a web app exists — Embryonaut's own
          # Sinatra app talks to Postgres directly (hence `pg` in its
          # Gemfile.lock) but that's that app's own choice, not a rule every
          # WebFunction follows. A web app that only ever dispatches through a
          # Lambda-routed domain (RemoteDispatcher/Adapters::Lambda, never a
          # local Postgres connection — hecks_on_web's own apps, e.g.) has no
          # `pg` gem and needs none of the native-extension patching below; the
          # generated Makefile's own `deploy:` target branches on whether this
          # is present, same convention `google_oauth_present` already uses for
          # its own opt-in machinery.
          pg_version = nil
          if web_handler_present
            # `dispatch "None"` reads this project's own root Gemfile.lock, not
            # #{domain}'s — WebFunction's own CodeUri is `root` in that case
            # (`web_code_uri`, below), not #{domain} itself, precisely because
            # #{domain} (a bluebook directory inside this very repo, e.g. "qa")
            # has no Gemfile of its own to bundle at all; it needs `lib/hecks`
            # and this project's own Gemfile.lock, sitting one level up. Every
            # other WebFunction (Embryonaut's own self-contained app checkout,
            # vendoring its own copy of hecks) keeps reading its own, unchanged.
            pg_version_path = File.join(dispatch_none ? root : domain, "Gemfile.lock")
            pg_version = File.read(pg_version_path)[/^\s+pg \(([\d.]+)\)/, 1]
          end
          web_logical_id = "WebFunction"

          # `dispatch "None"` — same reason `pg_version_path` reaches one
          # directory further up, above: #{domain} alone has no Gemfile/lib/hecks
          # of its own to zip, so WebFunction's CodeUri has to be this whole
          # project's own root instead (the identical absolute-path shape
          # Embryonaut's own real, live deploy already uses for a checkout that
          # isn't colocated with `deploy/<stack>/` either — bin/project_deploy's
          # own header: "Self-contained... no hand-authored deployment config").
          # `web_handler_relpath` follows the same split: #{domain}/lambda_handler
          # is only the right relative path once CodeUri stops being #{domain}
          # itself — every existing WebFunction (CodeUri: #{domain}) still finds
          # its own lambda_handler.rb at that directory's own root, unchanged.
          web_code_uri = dispatch_none ? root : domain
          web_handler_relpath = dispatch_none ? "#{domain}/lambda_handler" : "lambda_handler"

          # Opt-in, by file presence + content — the same convention
          # `web_handler_present` itself uses. `.env.local` is #{domain}'s own
          # gitignored local-dev secrets file (never committed, never read by
          # this tool for anything but detecting the key is there); the real
          # value is synced into Secrets Manager by `make sync-google-oauth`
          # below, straight from that same file, at deploy time — never baked
          # into this generated, git-tracked template.yaml as plaintext.
          # Also gates the NAT Gateway/public subnet template.yaml's own "no NAT
          # gateway" comment describes — computed here, once, before
          # stack_outputs/bastion_parameters below need to know whether
          # #{db_id}PublicSubnet exists at all to pass along to bastion.yaml.
          google_oauth_present = (web_handler_present || rust_web) &&
            File.exist?(File.join(domain, ".env.local")) &&
            File.read(File.join(domain, ".env.local")).match?(/^GOOGLE_CLIENT_ID=\S/)

          # **The Ruby case stays refused** — a shared-instance Ruby WebFunction
          # needs its own cross-stack DATABASE_URL wiring this generator doesn't
          # build yet (web_handler_present's own Member-style direct-Postgres
          # binding), real, unbuilt design, not a small addition. This check
          # alone is why the google_oauth_present check below can assume
          # web_handler_present is already false by the time it runs — it always
          # aborts first when both are true.
          if shared && web_handler_present
            raise ArgumentError, "#{domain} declares both database \"Shared\" and a lambda_handler.rb — a shared-instance Ruby WebFunction isn't supported yet."
          end

          # `dispatch "None"` means WebFunction becomes the domain's only Lambda —
          # there is nothing left to reach through a Function URL at all without a
          # `lambda_handler.rb` to serve it, and (below) no rust_web dispatch
          # Lambda whose own Function URL that role could fall back to either.
          if dispatch_none && !web_handler_present
            raise ArgumentError, "#{domain} declares dispatch \"None\" but has no lambda_handler.rb — dispatch \"None\" means no rust/host dispatch Lambda at all, so a WebFunction (lambda_handler.rb) has to exist to be the domain's only Lambda."
          end
          if dispatch_none && rust_web
            raise ArgumentError, "#{domain} declares both dispatch \"None\" and web \"Rust\" — dispatch \"None\" already means there is no rust/host Lambda for rust_web's own in-process web UI to run inside."
          end

          # **The Rust case is not refused** — rust_web's own OAuth wiring (the main
          # dispatch function's own Environment/VpcConfig, generated below) needs
          # no NAT Gateway of its own in Shared mode: it already runs inside the
          # owner's borrowed private subnets (OwningSubnetAId/OwningSubnetBId)
          # and borrowed security group (OwningSecurityGroupId) — the same ones
          # this domain's own dispatch traffic already uses — and the owner's own
          # template already routes those subnets through its NAT Gateway and
          # already permits 443-to-internet egress on that security group (added
          # there for the owner's own WebFunction's real, live OAuth
          # token-exchange bug — see that stack's own
          # `#{owner_domain_name}FunctionEgressToInternet` resource). Nothing new
          # to provision for this combination; the Parameters section below just
          # has to declare both the Owning* set (Shared mode) and
          # WebRedirectBaseUrl (OAuth) together, not as alternatives — see its
          # own comment on why an if/elsif there would be wrong.
          #
          # Still a real gap, left refused: rust_web isn't checked here
          # explicitly because shared && web_handler_present already aborted
          # above whenever web_handler_present is true — so by construction, if
          # `shared && google_oauth_present` is ever true at this point,
          # web_handler_present must be false, meaning google_oauth_present's own
          # `(web_handler_present || rust_web)` can only have been satisfied by
          # rust_web. Nothing left to refuse here.

          # The stack↔bastion contract, and the least-privilege cross-domain
          # invoke grant — `Shared`'s own header explains why both are
          # `Fargate`'s problem too, not only this target's.
          stack_outputs = Shared.stack_outputs(
            shared: shared, db_id: db_id, db_ref_id: db_ref_id, secret_intrinsic: secret_intrinsic,
            compute_security_group_ref: "!Ref #{logical_id}SecurityGroup", google_oauth_present: google_oauth_present
          )
          bastion_parameters = Shared.bastion_parameters(shared: shared, google_oauth_present: google_oauth_present)
          Shared.check_bastion_parameters!(bastion_parameters, stack_outputs)

          # Computed here, as its own local, rather than as two heredocs
          # opened side by side inside the big template heredoc's own
          # interpolation below — a heredoc's body is read starting from
          # the line after it opens, so two on one line only stay
          # unambiguous as long as neither branch is ever edited to span
          # the other's own territory. An ordinary `if`/`else`, each
          # heredoc entirely inside its own branch, cannot develop that
          # failure mode at all.
          web_google_oauth_env_yaml =
            if google_oauth_present
              <<~GOOGLE.each_line.with_index.map { |l, i| i.zero? ? l : "        " + l }.join.rstrip
                # BY NAME, not `!Ref`/`!GetAtt` -- #{web_logical_id}GoogleOauth
                # is deliberately NOT declared as a CloudFormation resource
                # here (would need either GenerateSecretString, which can't
                # invent a real Google client_id/secret, or a value baked
                # into this git-TRACKED template as plaintext). `make
                # sync-google-oauth` owns this secret's whole lifecycle
                # instead, straight from #{domain}'s own gitignored
                # .env.local, outside CloudFormation entirely. GetSecretValue
                # accepts a bare name directly, no ARN needed -- same
                # generator-only caveat as DB_SECRET_ARN's own comment above.
                GOOGLE_OAUTH_SECRET_ID: #{stack_name}-web-google-oauth
                GOOGLE_REDIRECT_URI: !Sub "${WebRedirectBaseUrl}/auth/google/callback"
              GOOGLE
            else
              <<~NOOAUTH.each_line.with_index.map { |l, i| i.zero? ? l : "        " + l }.join.rstrip
                # GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET/GOOGLE_REDIRECT_URI
                # deliberately NOT set here — #{domain}'s own .env.local has
                # no real GOOGLE_CLIENT_ID yet, matching Fly's own current
                # reality (fly secrets list -a embryonaut-founder-app: only
                # DATABASE_URL and SESSION_SECRET) that nobody has configured
                # OAuth for this app at all. Drop real credentials into
                # .env.local and regenerate to wire this up.
              NOOAUTH
            end

          template_yaml = <<~YAML
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
            # this file rather than hand-editing. Source: #{world_file}'s own
            # deployed_to("AwsLambda") block.
            #
            # SELF-CONTAINED, ON PURPOSE — this stack owns its own private VPC,
            # subnets, security groups, and RDS Postgres instance, not just the
            # Lambda. No externally-supplied VPC/database parameters, no
            # DatabaseUrl secret anyone has to type: RDS's own
            # ManageMasterUserPassword generates and stores the password in
            # Secrets Manager, and DATABASE_URL is composed from it via a
            # CloudFormation dynamic reference — resolved at deploy time, never
            # visible in this template, a parameter, or any tool's output.
            #
            # NO NAT GATEWAY for #{logical_id} — deliberately. Its own subnets
            # have no route to the internet at all, only to the RDS instance
            # inside the same VPC: dispatch a command, read/write the journal.
            # CloudWatch Logs delivery doesn't go through the function's own VPC
            # networking, so it needs no route either.
            #{google_oauth_present ? "  #\n  # #{web_logical_id} is the ONE exception -- real Google OAuth token\n  # exchange (hecks's own GoogleAuthentication adapter posting to\n  # https://oauth2.googleapis.com/token) is a genuine third-party HTTPS\n  # call with no AWS PrivateLink/VPC Endpoint option (unlike\n  # lambda:InvokeFunction, above), and #{web_logical_id} is ALSO\n  # VPC-attached (Member's own permanent Postgres binding needs the\n  # private RDS instance directly). A real, live 15-second Lambda\n  # timeout caught this -- the token-exchange POST had nowhere to\n  # route to and just hung. #{db_id}NatGateway below is the real,\n  # ongoing-cost fix (one NAT Gateway, one public subnet) -- opt-in,\n  # the SAME google_oauth_present signal that wires\n  # GOOGLE_CLIENT_ID/SECRET, since nothing else in this stack needs\n  # outbound internet at all." : "  # Real outbound internet access from here (a future external API\n  # call, say) would need a NAT Gateway added -- a real, ongoing cost\n  # this template doesn't take on until something actually needs it."}
            AWSTemplateFormatVersion: '2010-09-09'
            Transform: AWS::Serverless-2016-10-31
            Description: >
              #{infra_name} — dispatched through hecks's rust/host, a
              wasmtime-sandboxed Rust binary with a rehydrate-and-replay Postgres
              journal (docs/decisions/0018), backed by its own private RDS
              Postgres instance. PackageType Zip, no container.
            #{
              # Two independent reasons a Parameters section might be needed --
              # google_oauth_present (any web mode) and shared (any domain
              # borrowing an owner's VPC) -- are collected into one array and
              # joined under a single `Parameters:` header (YAML permits exactly
              # one), rather than treated as mutually exclusive alternatives via
              # an if/elsif/else here. That shape breaks for the one combination
              # both can be true at once (a Shared-mode rust_web domain with
              # real Google OAuth): the elsif branch would never run, so
              # OwningSubnetAId/OwningSecurityGroupId/etc. would never get declared as
              # Parameters at all, even though VpcConfig below (`shared ?
              # "SubnetIds: [!Ref OwningSubnetAId, ...]" : ...`) already
              # references them unconditionally whenever `shared` is true --
              # exactly the CloudFormation-references-an-undeclared-Parameter
              # break bastion_parameters' own generation-time assertion (above)
              # exists to catch for a different table. This fixes it for both
              # the "either" and the "both" case.
              param_blocks = []
              if google_oauth_present
                param_blocks << <<~OAUTHPARAMS.rstrip
                  # Lambda Function URLs get a random, un-derivable hostname at
                  # creation -- #{web_logical_id}'s own GOOGLE_REDIRECT_URI can't
                  # reference `!GetAtt #{web_logical_id}Url.FunctionUrl` from inside
                  # #{web_logical_id}'s OWN Environment (that's a real circular
                  # dependency CloudFormation rejects: the value doesn't exist until
                  # the function+URL do). Resolved OUTSIDE the stack instead --
                  # `make deploy`'s own recipe looks up the CURRENTLY deployed
                  # Function URL (empty on a true first deploy, before the URL
                  # exists at all) and passes it as `--parameter-overrides`; every
                  # deploy after the first self-heals this correctly.
                  WebRedirectBaseUrl:
                    Type: String
                    Default: ""
                OAUTHPARAMS
              end
              if shared
                param_blocks << <<~SHAREDPARAMS.rstrip
                  # THE STOREHOUSE — #{owner_domain_name}'s own live stack Outputs,
                  # looked up at deploy time (Makefile's own `deploy:`/`mint-era`
                  # targets, below) via the SAME `aws cloudformation describe-stacks`
                  # pattern `mint-era` already used for a bastion, one stack over
                  # instead of one sibling stack over. Never a CloudFormation
                  # Export/ImportValue -- this codebase uses none anywhere (bin/
                  # project_deploy's own header on why: a live shell lookup keeps
                  # this stack independently deployable/deletable, never coupled to
                  # #{owner_domain_name}'s own stack through CloudFormation itself).
                  OwningVpcId:
                    Type: AWS::EC2::VPC::Id
                  OwningSubnetAId:
                    Type: AWS::EC2::Subnet::Id
                  OwningSubnetBId:
                    Type: AWS::EC2::Subnet::Id
                  # #{owner_domain_name}'s own Lambda security group, NOT its
                  # DB-facing one -- reused whole, not copied, the same shape
                  # this codebase already trusts elsewhere (a WebFunction sharing
                  # its own dispatch Lambda's security group rather than minting
                  # a second one), one stack over instead of one resource over.
                  # #{owner_domain_name}'s own DB security group already permits
                  # ingress FROM this group (every member of it, regardless of
                  # which stack minted the member -- security group references
                  # match on GROUP MEMBERSHIP, not resource identity), so joining
                  # it is what actually grants this Lambda access, not a new
                  # ingress rule #{owner_domain_name}'s own stack would otherwise
                  # need to add.
                  OwningSecurityGroupId:
                    Type: AWS::EC2::SecurityGroup::Id
                  OwningDatabaseEndpoint:
                    Type: String
                  OwningDatabaseSecretArn:
                    Type: String
                SHAREDPARAMS
              end
              if param_blocks.empty?
                ""
              else
                # Every line indented 2, not just appended flush-left — each
                # heredoc above squiggly-dedents to column 0 (its own
                # least-indented line, matching every other heredoc's own
                # convention in this file), but these are Parameters: children,
                # which YAML requires indented under it. Confirmed the hard way:
                # without this, `ruby -ryaml` parses the file without raising
                # (it's still syntactically valid YAML) but
                # `doc["Parameters"]["OwningVpcId"]` is nil — WebRedirectBaseUrl/
                # OwningVpcId/etc. land as their own top-level document keys,
                # siblings of Parameters/Resources, not children of Parameters
                # at all.
                "Parameters:\n" + param_blocks.join("\n").each_line.map { |l| "  #{l}" }.join
              end
            }
            Resources:
              #{shared ? "" : Shared.vpc_and_database_yaml(
                db_id: db_id, db_name: db_name, infra_name: infra_name, aurora: aurora,
                google_oauth_present: google_oauth_present, compute_logical_id: logical_id,
                compute_description: "#{logical_id} - no inbound (Lambda receives no traffic via its VPC ENI), egress rule attached separately below"
              ).each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip}

              #{rust_web && google_oauth_present ? <<~RUSTSECRET.each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip : ""}
              # Auto-generated, never typed or seen -- rust/host's own
              # auth.rs signs both the session cookie and the OAuth `state`
              # token with this. Same ManageMasterUserPassword-style pattern
              # #{db_id} already uses for its own password.
              #{logical_id}SessionSecret:
                Type: AWS::SecretsManager::Secret
                Properties:
                  GenerateSecretString:
                    SecretStringTemplate: '{}'
                    GenerateStringKey: session_secret
                    PasswordLength: 64
                    ExcludePunctuation: true

              RUSTSECRET
              #{logical_id}:
                Type: AWS::Serverless::Function#{aurora ? "\n    # `{{resolve:secretsmanager:...}}` dynamic references do NOT\n    # create an implicit CloudFormation dependency on the referenced\n    # resource (documented AWS behavior) -- #{logical_id}'s own\n    # Environment resolves one against #{db_id}Secret below. A plain\n    # `DependsOn: #{db_id}Secret` alone (CREATE_COMPLETE before this\n    # resource's own update starts) still hit a real, live, repeatable\n    # \"Secrets Manager can't find the specified secret\n    # (ResourceNotFoundException)\" -- CREATE_COMPLETE from\n    # CloudFormation's own perspective doesn't guarantee the secret is\n    # yet READABLE via a dynamic reference from a DIFFERENT resource's\n    # own concurrent update (AWS-side eventual consistency, not a\n    # CloudFormation ordering bug `DependsOn` alone can close).\n    # Chaining through #{db_id}Cluster too -- which ALSO reads this\n    # secret, and whose own RDS-side update takes real, substantial\n    # wall-clock time to apply -- gives that propagation window time\n    # to close before #{logical_id}'s own resolution is attempted.\n    DependsOn: [#{db_id}Secret, #{db_id}Cluster]" : ""}
                Metadata:
                  BuildMethod: makefile
                Properties:
                  # PINNED, not SAM's own auto-suffixed default — a Ruby-side
                  # LambdaClient needs to know this function's name AHEAD OF a
                  # first deploy (there's no chicken-egg lookup step), the same
                  # "configured for me, in the projection" standard every other
                  # piece of generated deploy config already holds to. Matches
                  # `stack_name` above exactly — one name, two places it's read
                  # from, never out of sync since both derive from `infra_name`.
                  FunctionName: #{stack_name}
                  # EXPLICIT, not omitted -- `sam build EmbryonautFunction` and
                  # `sam build --use-container WebFunction` run as TWO SEPARATE
                  # single-resource invocations (deploy:'s own comment on why:
                  # cargo-lambda cross-compiles on this host directly, pg's
                  # native extension needs the container -- `--use-container` is
                  # a global sam build flag, can't be scoped per-resource). Each
                  # invocation regenerates .aws-sam/build/template.yaml from
                  # THIS source template for every resource, not just the one it
                  # builds -- a resource with no CodeUri here reverts to
                  # CodeUri-less after the SECOND invocation, and `sam deploy`
                  # then defaults a missing CodeUri to the template's own
                  # containing directory (deploy/#{infra_name}/ itself),
                  # zipping the whole project tree -- including WebFunction's
                  # own source -- as this function's code. A real, live deploy
                  # shipped exactly that broken artifact (confirmed via
                  # `aws lambda get-function` + downloading the actual deployed
                  # zip). Pinning CodeUri here survives that regeneration: it
                  # still resolves to `.aws-sam/build/#{logical_id}/`, where
                  # build-#{logical_id}'s own `cp ... $(ARTIFACTS_DIR)` already
                  # placed the real bootstrap+wasm, regardless of which of the
                  # two sam build calls ran most recently.
                  # "." NOT "#{logical_id}" -- SAM's Makefile build workflow
                  # requires the Makefile to live INSIDE CodeUri itself
                  # (confirmed live: "Makefile not found at
                  # .../EmbryonautFunction/Makefile" when CodeUri named a
                  # directory of its own). This project's one Makefile lives at
                  # the deploy directory's own root, alongside this template --
                  # "." is where it actually is.
                  CodeUri: .
                  PackageType: Zip
                  Runtime: provided.al2023
                  Architectures: [arm64]
                  Handler: bootstrap
                  MemorySize: #{memory}
                  Timeout: #{timeout}
                  Environment:
                    Variables:
                      # NOT a `{{resolve:secretsmanager:...}}`-composed DATABASE_URL
                      # anymore (the WebFunction handler below still uses that
                      # mechanism, unchanged) -- that dynamic reference genuinely
                      # IS resolved fresh at deploy time and never rendered into
                      # this template, this tool's output, or the CloudFormation
                      # console. But once it resolves INTO a Lambda's own
                      # Environment.Variables entry, the resolved PLAINTEXT is
                      # stored in the function's OWN configuration:
                      # `lambda:GetFunctionConfiguration` returns it decrypted,
                      # and the Lambda console's Configuration tab displays it, to
                      # ANY principal holding read-only account access (AWS's own
                      # managed ReadOnlyAccess policy included) -- caught
                      # reviewing this template, not live; AWS's own guidance is
                      # to fetch a secret from Secrets Manager at RUNTIME instead,
                      # precisely to avoid this. DB_HOST/DB_NAME/DB_SECRET_ARN
                      # below are not secrets themselves -- an endpoint address, a
                      # database name, and a Secrets Manager ARN authenticate
                      # nothing on their own -- so sitting here as plain
                      # Environment.Variables values costs nothing; main.rs itself
                      # fetches the actual password from Secrets Manager at cold
                      # start, over the AWS SDK, and never hands it back to
                      # CloudFormation or Lambda's own configuration at all.
                      # #{logical_id}'s own least-privilege Policies grant (below,
                      # sibling of VpcConfig) is the one runtime IAM permission
                      # that fetch needs, scoped to this one secret ARN.
                      #{if shared
                          # **The storehouse** — #{owner_domain_name}'s own live
                          # Endpoint/Secret, looked up at deploy time into
                          # OwningDatabaseEndpoint/OwningDatabaseSecretArn (this
                          # template's own Parameters, above), not a resource in
                          # this stack. Same dbname as #{owner_domain_name}'s own
                          # DBName -- one database, isolated by schema
                          # (HECKS_SCHEMA below), not a second database.
                          "DB_HOST: !Ref OwningDatabaseEndpoint\n" \
                          "          DB_NAME: #{owner_db_name}\n" \
                          "          DB_SECRET_ARN: !Sub \"${OwningDatabaseSecretArn}\""
                        else
                          "DB_HOST: !GetAtt #{db_ref_id}.Endpoint.Address\n" \
                          "          DB_NAME: #{db_name}\n" \
                          "          DB_SECRET_ARN: !Sub \"${#{secret_sub}}\""
                        end}
                      # `domain_name`, NOT `infra_name` — this names the actual
                      # .wasm FILE bin/project_wasm writes (rust/dist/#{domain_name}.wasm,
                      # its own target_mod_name convention, a Rust-build-pipeline
                      # concern unrelated to AWS resource identity) and what the
                      # Makefile below actually bundles into the Lambda package
                      # under. Confirmed the hard way: pinning this to infra_name
                      # alongside the real AWS-identity fields left it looking for
                      # a file bin/project_wasm never produces.
                      HECKS_WASM_PATH: !Sub "/var/task/#{domain_name}.wasm"
                      # STATIC, not a deploy-time parameter — HECKS_DOMAIN is this
                      # domain's own declared name, known at generation time the
                      # same way DBName/HECKS_WASM_PATH already are. HECKS_ERA is
                      # "1" because that's what a FRESH database always gets:
                      # PostgresEra::LineageManager::EraResolver#check! mints era 1
                      # unconditionally the first time any Ruby process boots
                      # against an empty `hecks_eras` (era_resolver.rb's own
                      # `held.empty?` branch) — deterministic, not guessed. `make
                      # mint-era` (this directory's own Makefile) is what actually
                      # triggers that first boot; a LATER real schema evolution
                      # (era 2+) is a separate, later re-generation, not this one.
                      HECKS_DOMAIN: #{declared_domain_name}
                      HECKS_ERA: "1"#{hecks_schema ? %(\n          HECKS_SCHEMA: #{hecks_schema}) : ""}#{rust_web ? %(\n          HECKS_IR_PATH: !Sub "/var/task/#{domain_name}.ir.json") : ""}#{rust_web && google_oauth_present ? <<~RUSTOAUTH.each_line.with_index.map { |l, i| i.zero? ? "\n          " + l : "          " + l }.join.rstrip : ""}
                      # NOT `{{resolve:secretsmanager:...}}` composing
                      # GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET/SESSION_SECRET
                      # directly anymore -- the identical GetFunctionConfiguration
                      # exposure DATABASE_URL's own comment above documents
                      # applied here too. main.rs's own cold start fetches both
                      # secrets itself and `set_var`s the real GOOGLE_CLIENT_ID/
                      # GOOGLE_CLIENT_SECRET/SESSION_SECRET keys before anything
                      # else runs -- auth.rs/web.rs still read those exact keys,
                      # unchanged. GOOGLE_OAUTH_SECRET_ID is a bare NAME (`make
                      # sync-google-oauth` owns #{stack_name}-web-google-oauth's
                      # whole lifecycle outside CloudFormation, straight from
                      # #{domain}'s own gitignored .env.local, never baked into
                      # this generated, git-tracked template as plaintext) --
                      # GetSecretValue accepts a name directly, no ARN needed.
                      GOOGLE_OAUTH_SECRET_ID: #{stack_name}-web-google-oauth
                      GOOGLE_REDIRECT_URI: !Sub "${WebRedirectBaseUrl}/auth/google/callback"
                      SESSION_SECRET_ARN: !Sub "${#{logical_id}SessionSecret}"
                      RUSTOAUTH
                  # LEAST-PRIVILEGE -- #{logical_id}'s own execution role is
                  # otherwise SAM's bare default (logging only); this is the one
                  # runtime AWS permission the DB_SECRET_ARN handling above needs,
                  # scoped to the single secret ARN this stack itself depends on,
                  # never `Resource: "*"`.
                  Policies:
                    - Statement:
                        - Effect: Allow
                          Action: secretsmanager:GetSecretValue
                          Resource: !Sub "${#{db_secret_ref}}"
                    #{rust_web && google_oauth_present ? <<~OAUTHPOLICY.each_line.with_index.map { |l, i| i.zero? ? l : "        " + l }.join.rstrip : ""}
                      - Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            # NAME-BASED, not `!Ref`/`!GetAtt` -- this secret is
                            # never a stack resource (RUSTOAUTH's own Environment
                            # comment, above, has the full story), so there is no
                            # exact ARN to point at. The trailing `-*` is AWS's
                            # own documented pattern for granting a secret known
                            # only by name: every real ARN Secrets Manager mints
                            # is this name plus a random 6-character suffix,
                            # which can't be predicted at template-render time.
                            Resource: !Sub "arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:#{stack_name}-web-google-oauth-*"
                      - Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Sub "${#{logical_id}SessionSecret}"
                      OAUTHPOLICY
                    # TMPL:cross_domain_lambda_policies
                  VpcConfig:
                    #{if shared
                        "SubnetIds: [!Ref OwningSubnetAId, !Ref OwningSubnetBId]\n        SecurityGroupIds: [!Ref OwningSecurityGroupId]"
                      else
                        "SubnetIds: [!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]\n        SecurityGroupIds: [!Ref #{logical_id}SecurityGroup]"
                      end}
                  # AWS_IAM by default — this dispatches real domain commands
                  # (cap-table/governance-shaped data, for Embryonaut's own use);
                  # an unauthenticated public URL is the wrong default for that,
                  # even though it's the simpler one to demo with. NONE only when
                  # `web "Rust"` (rust/host/src/web.rs) makes this the public web
                  # UI itself — safe even though the SAME Function URL also
                  # carries the internal {"verb"}/{"read"} dispatch shapes,
                  # because a Function-URL HTTP event can never be crafted into
                  # that raw top-level shape (Function URLs always wrap the real
                  # HTTP body inside requestContext.http/rawPath/event.body,
                  # unconditionally); that raw shape is reachable only through
                  # the AWS SDK's own IAM-authenticated Invoke API, which never
                  # goes through a Function URL at all.
                  FunctionUrlConfig:
                    AuthType: #{rust_web ? "NONE" : "AWS_IAM"}
            #{web_handler_present ? <<~WEB.each_line.map { |l| "  " + l }.join : ""}
            # THE WEB APP'S OWN LAMBDA — opt-in, see `web_handler_present` above.
            # VPC-attached for the SAME reason #{logical_id} is (Member's own
            # persistence needs the private RDS instance directly, permanently —
            # embryonaut.hecksagon's own comment on why), sharing
            # #{logical_id}SecurityGroup rather than minting a second one, since
            # both need the identical egress-to-DB rule. That VPC attachment
            # ALSO cuts off the public internet by default (this stack's own "NO
            # NAT GATEWAY" design) — but this function has to reach
            # #{logical_id} itself via `lambda:InvokeFunction`, a public AWS API
            # call. #{web_logical_id}LambdaEndpoint below is the targeted fix: a
            # VPC Interface Endpoint for the Lambda service ONLY (not a NAT
            # Gateway) — a few dollars a month, not a general internet route.
            #{db_id}LambdaEndpointSecurityGroup:
              Type: AWS::EC2::SecurityGroup
              Properties:
                VpcId: !Ref #{db_id}Vpc
                # EC2's own GroupDescription character set excludes apostrophes
                # too, not just em-dashes -- "this stack's own" was a real,
                # live rejection ("Invalid security group description").
                GroupDescription: #{db_id}LambdaEndpoint - HTTPS from this stacks own Lambdas only

            #{db_id}LambdaEndpointIngress:
              Type: AWS::EC2::SecurityGroupIngress
              Properties:
                GroupId: !Ref #{db_id}LambdaEndpointSecurityGroup
                IpProtocol: tcp
                FromPort: 443
                ToPort: 443
                SourceSecurityGroupId: !Ref #{logical_id}SecurityGroup

            #{db_id}LambdaEndpoint:
              Type: AWS::EC2::VPCEndpoint
              Properties:
                VpcId: !Ref #{db_id}Vpc
                ServiceName: !Sub "com.amazonaws.${AWS::Region}.lambda"
                VpcEndpointType: Interface
                PrivateDnsEnabled: true
                SubnetIds: [!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]
                SecurityGroupIds: [!Ref #{db_id}LambdaEndpointSecurityGroup]

            # Auto-generated, never typed or seen — the SAME
            # ManageMasterUserPassword pattern #{db_id} already uses for its own
            # password, applied to Sinatra's own session-signing secret instead.
            #{web_logical_id}SessionSecret:
              Type: AWS::SecretsManager::Secret
              Properties:
                GenerateSecretString:
                  SecretStringTemplate: '{}'
                  GenerateStringKey: session_secret
                  PasswordLength: 64
                  ExcludePunctuation: true

            #{webhook_secret_env ? <<-WEBHOOKSECRET : ""}
          # Auto-generated, never typed or seen — the SAME
          # ManageMasterUserPassword/SessionSecret pattern above, applied to
          # `secret_env`'s own webhook secret instead (deploy_settings' own
          # `secret_env`, read far above). #{web_logical_id}'s own
          # `lambda_handler.rb` fetches this by ARN at cold start (the
          # `#{webhook_secret_env}_ARN` Environment variable below) and exposes
          # its plaintext under `ENV["#{webhook_secret_env}"]` itself — the
          # SAME two-step indirection DB_SECRET_ARN/SESSION_SECRET_ARN already
          # use, and for the identical reason (this Environment block's own
          # header comment on why a resolved plaintext must never land in
          # Lambda's own configuration).
          #{web_logical_id}WebhookSecret:
            Type: AWS::SecretsManager::Secret
            Properties:
              GenerateSecretString:
                SecretStringTemplate: '{}'
                GenerateStringKey: value
                PasswordLength: 64
                ExcludePunctuation: true

            WEBHOOKSECRET
            #{web_logical_id}:
              Type: AWS::Serverless::Function
              # NO Metadata.BuildMethod — "bundler" isn't a real SAM value (a
              # real, live UnsupportedBuilderException caught this); `Runtime:
              # ruby3.2` alone is enough for SAM to select its own built-in Ruby
              # bundler workflow automatically. #{logical_id}'s own `BuildMethod:
              # makefile` above is different: rust/host isn't a runtime SAM
              # knows how to build at all, so it needs an explicit custom
              # workflow — this function doesn't. STAYS `ruby3.2` deliberately,
              # even though `sam validate --lint` now flags it deprecated
              # (2026-03-31, creation disabled 2027-02-01, still comfortably
              # ahead of today) — `patch-pg-native`'s own build-ruby3.2 container
              # image and `lib/3.2/pg_ext.so` path glob (this Makefile, below)
              # are BOTH hardcoded to this exact runtime; bumping Runtime alone
              # without reworking that whole from-source pg build for a newer
              # image is a real, separate undertaking (untested container image
              # availability, a different vendor/bundle native-extension path)
              # out of scope here. Matches Embryonaut's own live, currently-
              # deployed choice exactly, so both consumers of this one shared
              # WebFunction code path stay on the same, PROVEN runtime.
              Properties:
                FunctionName: #{stack_name}-web
                Runtime: ruby3.2
                Architectures: [arm64]
                # THREE parts (file.Class.method), not two — aws-lambda-ric's own
                # 2-part form calls a plain TOP-LEVEL function via __send__, not
                # a module method; #{web_handler_relpath}.rb's own comment on
                # why its module is named the way it is explains the rest — a
                # real, live "LambdaHandler is not a module" caught both halves
                # of this the hard way. `web_handler_relpath` (not a bare
                # "lambda_handler") whenever `dispatch "None"` moved CodeUri off
                # #{domain} itself — see that variable's own comment, above.
                Handler: #{web_handler_relpath}.#{webhook_handler_module}.lambda_handler
                CodeUri: #{web_code_uri}
                MemorySize: 512
                Timeout: 15
                Environment:
                  Variables:
                    DOMAIN_ROOT: /var/task
                    # NOT `declared_domain_name` — `Adapters::Lambda`/
                    # `RemoteDispatcher` both read this to compute WHICH
                    # deployed Lambda function to invoke (`hecks-\#{...}`,
                    # matching this stack's own name), a question `infra_name`
                    # answers and a domain's own business identity does not.
                    # Real, live, and confirmed the hard way: this was still
                    # wired to `declared_domain_name` when EmbryonautFoundersApp
                    # first deployed, and WebFunction immediately threw
                    # `ResourceNotFoundException: Function not found:
                    # hecks-embryonautfoundersapp` on every read AND on the
                    # Google OAuth callback itself — a real signed-in user hit
                    # this within minutes of the deploy that introduced it.
                    DOMAIN_NAME: #{infra_name}
                    HECKS_LAMBDA_ROUTING: "true"
                    HECKS_LAMBDA_REGION: #{region}#{hecks_schema ? %(\n        HECKS_SCHEMA: #{hecks_schema}) : ""}
                    # SAME setting #{domain}'s own fly.toml/Dockerfile already
                    # sets for the Fly deployment this one replaces — Sinatra's
                    # own `host_authorization` default is only PERMISSIVE in
                    # production mode (an empty `permitted_hosts` list means
                    # "allow any host" — checked directly in rack-protection's
                    # own source); its DEVELOPMENT default is the restrictive
                    # one (only localhost/.test), which is what Sinatra falls
                    # back to when NEITHER RACK_ENV nor APP_ENV is set. A real,
                    # live "Host not permitted" 403 against this function's own
                    # unpredictable *.lambda-url.*.on.aws hostname caught the
                    # gap — this function's Environment never set either var.
                    RACK_ENV: production
                    # The precompiled `pg` gem's aarch64-linux native extension
                    # needs GLIBC 2.29+; Lambda's ruby3.2 MANAGED runtime is
                    # Amazon Linux 2 (glibc 2.26) -- a real, live "Init<NameError>:
                    # uninitialized constant PG::Error" caught this (rescuing
                    # PG::Error itself failed to resolve, because pg's own
                    # require died before reaching the file that defines it).
                    # `make deploy`'s own `patch-pg-native` step (this directory's
                    # Makefile) replaces the broken precompiled extension with one
                    # compiled from source, in-container, against a real
                    # SSL-enabled libpq -- and drops that libpq's .so beside it at
                    # /var/task/lib, found by the dynamic loader with NO explicit
                    # LD_LIBRARY_PATH override needed: the base ruby3.2 image's
                    # own baked-in default (`docker inspect
                    # public.ecr.aws/lambda/ruby:3.2-arm64`) is already
                    # "/var/lang/lib:/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib:/opt/lib"
                    # -- setting LD_LIBRARY_PATH here as a Lambda env var
                    # REPLACES that whole list rather than extending it (a real,
                    # live gotcha: Lambda env vars always fully override a
                    # same-named baked-in image env, never merge with it), which
                    # is exactly what broke Ruby's OWN interpreter startup
                    # ("libcrypt.so.1: cannot open shared object file") the one
                    # time this was set explicitly, before libpq.so.5.16 itself
                    # ever got a chance to matter.
                    # Member's own permanent Postgres connection — the SAME RDS
                    # instance #{logical_id} itself writes rust/host's flat
                    # journal into, different database engine role (Ruby's own
                    # era/lineage schema, not rust/host's), never the real
                    # Fly-hosted Postgres this whole effort is retiring away from.
                    #
                    # GENERATOR-ONLY FIX, NOT YET SAFE TO DEPLOY — DB_HOST/DB_NAME/
                    # DB_SECRET_ARN/SESSION_SECRET_ARN/GOOGLE_OAUTH_SECRET_ID below
                    # replace the SAME `{{resolve:secretsmanager:...}}`-into-
                    # Environment.Variables shape rust/host's own main.rs (this
                    # template's own #{logical_id}) used to have -- readable in
                    # plaintext by any read-only account principal via
                    # lambda:GetFunctionConfiguration, the exact exposure
                    # #{logical_id}'s own comment above the Policies section
                    # documents. But THIS function's consumer (`lambda_handler.rb`)
                    # is not a file this generator writes or this repo carries --
                    # it lives in the deploying app's own domain directory (real,
                    # live example: Embryonaut's own Sinatra app), outside this
                    # codebase entirely. Redeploying a domain with an existing
                    # `lambda_handler.rb` BEFORE that handler is updated to fetch
                    # these itself (`aws-sdk-secretsmanager`, not yet in this
                    # project's own Gemfile) breaks it: it still expects
                    # `ENV["DATABASE_URL"]`/`ENV["SESSION_SECRET"]`/
                    # `ENV["GOOGLE_CLIENT_ID"]`/`ENV["GOOGLE_CLIENT_SECRET"]`
                    # already resolved, and none of those keys exist below anymore.
                    DB_HOST: !GetAtt #{db_ref_id}.Endpoint.Address
                    DB_NAME: #{db_name}
                    DB_SECRET_ARN: !Sub "${#{secret_sub}}"
                    SESSION_SECRET_ARN: !Sub "${#{web_logical_id}SessionSecret}"#{webhook_secret_env ? %(\n        #{webhook_secret_env}_ARN: !Sub "${#{web_logical_id}WebhookSecret}") : ""}
                    #{web_google_oauth_env_yaml}
                VpcConfig:
                  SubnetIds: [!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]
                  SecurityGroupIds: [!Ref #{logical_id}SecurityGroup]
                # LEAST-PRIVILEGE, scoped to #{logical_id}'s own ARN specifically
                # (SAM's own LambdaInvokePolicy template) — WebFunctionRole is
                # otherwise SAM's bare default execution role (logging only), and
                # had NO lambda:InvokeFunction permission at all until this: a
                # real, live AccessDeniedException caught it, the same request
                # that also caught the wrong-function-name bug just above
                # (WebFunctionRole is not authorized... on resource
                # hecks-task — this stack has never had ANY policy granting
                # that action, so the fix isn't complete without adding one).
                # THE SAME secretsmanager:GetSecretValue GRANTS #{logical_id}'s
                # own Policies section (above) needed, once this function's own
                # `lambda_handler.rb` fetches DB_SECRET_ARN/SESSION_SECRET_ARN/
                # GOOGLE_OAUTH_SECRET_ID itself instead of relying on a resolved
                # Environment.Variables value -- see this Environment block's own
                # comment for why that consumer-side change isn't in this repo.
                Policies:
                  - LambdaInvokePolicy:
                      FunctionName: !Ref #{logical_id}
                  - Statement:
                      - Effect: Allow
                        Action: secretsmanager:GetSecretValue
                        Resource: !Sub "${#{secret_sub}}"
                  - Statement:
                      - Effect: Allow
                        Action: secretsmanager:GetSecretValue
                        Resource: !Sub "${#{web_logical_id}SessionSecret}"#{webhook_secret_env ? %(\n      - Statement:\n          - Effect: Allow\n            Action: secretsmanager:GetSecretValue\n            Resource: !Sub "${#{web_logical_id}WebhookSecret}") : ""}
                  #{google_oauth_present ? <<~WEBOAUTHPOLICY.each_line.with_index.map { |l, i| i.zero? ? l : "      " + l }.join.rstrip : ""}
                    - Statement:
                        - Effect: Allow
                          Action: secretsmanager:GetSecretValue
                          Resource: !Sub "arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:#{stack_name}-web-google-oauth-*"
                    WEBOAUTHPOLICY
                # NONE, not AWS_IAM — real users need to reach sign-in over
                # plain HTTPS, unlike #{logical_id}'s own AWS_IAM-protected URL
                # (this function is the ONLY thing meant to call that one).
                FunctionUrlConfig:
                  AuthType: NONE
            WEB

            Outputs:
              FunctionUrl:
                Value: !GetAtt #{logical_id}Url.FunctionUrl#{web_handler_present ? "\n  WebFunctionUrl:\n    Value: !GetAtt #{web_logical_id}Url.FunctionUrl" : ""}
              # stack_outputs (bin/project_deploy, above the heredocs) is the ONE
              # place these four names live — DatabaseEndpoint/DatabaseSecretArn
              # feed `make mint-era`'s own boot step directly; VpcId/
              # DbSecurityGroupId ALSO feed bastion.yaml's own Parameters (a
              # separate, sibling stack, created only for the few minutes a mint
              # takes and destroyed right after, attaching into the SAME private
              # network without this main template ever knowing a bastion
              # exists) and the Makefile's own --parameter-overrides. Rename a
              # key in that table and every consumer follows; reference one that
              # doesn't exist there and bin/project_deploy refuses before
              # writing a single file, instead of a bastion.yaml whose Parameter
              # nothing could ever fill. (`PrivateSubnetId` used to sit here too
              # — dropped, nothing ever consumed it; bastion.yaml mints its own
              # subnet instead.)
              #{stack_outputs.map { |o| "#{o[:key]}:\n    Value: #{o[:ref]}" }.join("\n  ")}
          YAML

          # Spliced in after the heredoc renders, not interpolated inside it —
          # found live, the hard way: `<<~`'s own dedent strips whatever the
          # shallowest leading-whitespace line in the raw source text has, computed
          # before any `#{...}` interpolation runs. `cross_domain_lambda_policies`
          # is "" for the overwhelmingly common case (no cross-domain policies at
          # all), and a `#{...}` marker written at column 0 in the source (so it
          # renders flush when empty) is itself a zero-indent line by that same
          # raw-text measure — dragging the whole heredoc's computed dedent down to
          # zero and leaving every other line's original leading whitespace
          # un-stripped, a real, generated-then-caught-by-spec bug (`bin/
          # project_deploy`'s own contract spec: "Outputs only declares []" — not
          # actually empty, just re-indented into structural nonsense by this).
          # A plain, unconditional `String#sub` after the fact has no such
          # interaction with the text it's replacing into.
          template_yaml = template_yaml.sub(/^([ \t]*)# TMPL:cross_domain_lambda_policies\n/) { Shared.cross_domain_invoke_policy_yaml(cross_domain_lambda_targets, $1) }

          # **The `PII` → CloudFront splice** — operates on the already-fully-rendered
          # string, the same reason the `dispatch_none` splice (below) does rather
          # than threading a third reindentation layer through the main heredoc
          # above: `pii_cloudfront_yaml` builds its own already-correctly-indented
          # text from scratch (its own `reindent` lambda), so there is nothing here
          # for a heredoc dedent computation to interact with badly.
          # `fronted_logical_id`/`use_oac` are resolved here, not earlier, because
          # both need `web_handler_present`/`web_logical_id`/`rust_web`/`logical_id`
          # — every one of which is computed after this generator's own pii
          # detection, above.
          if pii_detected
            fronted_logical_id = web_handler_present ? web_logical_id : logical_id
            use_oac             = !web_handler_present && !rust_web

            pii_resources = pii_cloudfront_yaml(
              fronted_logical_id: fronted_logical_id, use_oac: use_oac,
              geo_restriction_type: geo_restriction_type, geo_restriction_countries: geo_restriction_countries
            )
            template_yaml = template_yaml.sub(/^Outputs:\n/) { "#{pii_resources}Outputs:\n  PiiDistributionDomainName:\n    Value: !GetAtt PiiDistribution.DomainName\n" }
          end

          # `dispatch "None"` — surgical removal, POST-render, rather than a
          # fourth reindentation layer threaded through the heredoc above.
          # Tried that first: wrapping `#{logical_id}`'s own resource block in a
          # conditional nested heredoc (matching `RUSTSECRET`/`WEB`/`OWNDB`'s own
          # established `<<~TAG.each_line.with_index.map { ... }` convention)
          # looked right, but broke several pre-existing embedded multi-line
          # `#{shared ? "a\nb" : "c"}`-shaped strings already living inside that
          # block (the DB_HOST/DB_NAME/DB_SECRET_ARN Environment lines among
          # them) — those assume they sit at exactly one reindentation layer deep
          # (the outer template heredoc's own margin), and adding a second layer
          # on top shifted every line their own hardcoded embedded-newline
          # indentation didn't already account for. Confirmed live, diffing a
          # real regenerated examples/banking (`dispatch` unset — the ordinary,
          # far more common path) against its own git-tracked output: real
          # indentation corruption, not a false alarm. Operating on the already-
          # fully-rendered, already-correctly-indented string instead sidesteps
          # that whole class of interaction — no new heredoc layer, so nothing
          # already living inside the old one has to change its own assumptions.
          if dispatch_none
            # The #{logical_id} resource itself — non-greedy through its own
            # `FunctionUrlConfig`/`AuthType` closing pair (the actual last
            # property this resource ever renders, confirmed above), so a second
            # occurrence of "AuthType:" later in the document (WebFunction's own,
            # always AuthType: `NONE`) can never be matched instead.
            template_yaml = template_yaml.sub(
              /^  #{Regexp.escape(logical_id)}:\n.*?\n        AuthType: (?:NONE|AWS_IAM)\n/m, ""
            )
            # WebFunction's own Policies — `LambdaInvokePolicy: FunctionName: !Ref
            # #{logical_id}` grants invoking a function that, above, was just
            # removed from this template entirely; SAM refuses a `!Ref` to an
            # undeclared resource at package time, not silently.
            template_yaml = template_yaml.sub(
              /^        - LambdaInvokePolicy:\n            FunctionName: !Ref #{Regexp.escape(logical_id)}\n/, ""
            )
            # Outputs — no `#{logical_id}Url` exists any more for `FunctionUrl` to
            # `!GetAtt`; WebFunction's own URL becomes the stack's one and only
            # "FunctionUrl" (never "WebFunctionUrl" — that name is reserved for
            # the two-URL case, a domain that also has a #{logical_id} of its
            # own to disambiguate from, which this one, by construction, never
            # does).
            template_yaml = template_yaml.sub(
              /^  FunctionUrl:\n    Value: !GetAtt #{Regexp.escape(logical_id)}Url\.FunctionUrl\n  WebFunctionUrl:\n    Value: !GetAtt #{Regexp.escape(web_logical_id)}Url\.FunctionUrl\n/,
              "  FunctionUrl:\n    Value: !GetAtt #{web_logical_id}Url.FunctionUrl\n"
            )
          end



          # **The ephemeral era-minting bastion** — a separate, sibling stack
          # (`#{stack_name}-bastion`), never merged into template.yaml itself.
          # The main stack stays exactly as minimal as its own header already
          # commits to (no NAT gateway, no bastion sitting there costing money
          # by default) — this template only ever exists for the few minutes
          # `make mint-era` (below) needs it, then gets deleted. SSM Session
          # Manager only, never SSH: no key pair, no inbound security group rule
          # at all (the instance's own SG declares zero Ingress) — the only way
          # in is `aws ssm start-session`, itself gated by the caller's own IAM
          # permissions, nothing this template opens to the internet.
          # Skipped entirely when `shared` — this domain provisions no RDS/VPC
          # of its own for a bastion to reach (bastion_parameters is empty for
          # the same reason, above); a bare `!Ref VpcId` with no declared
          # Parameter would just fail at deploy time. Era-minting for a
          # Shared-mode domain reuses its owner's own already-standing
          # infrastructure instead — see the Makefile's own `mint-era` comment
          # for the manual path this leaves until that's automated too.
bastion_yaml = shared ? nil : Shared.bastion_yaml(
  domain: domain, infra_name: infra_name, stack_name: stack_name, db_id: db_id,
  google_oauth_present: google_oauth_present, bastion_parameters: bastion_parameters
)

          # `mint-era`'s own recipe body — a top-level variable, not inlined at
          # its call site inside the Makefile heredoc below, on purpose: Make
          # recipe lines need a literal tab as their true first character (no
          # leading spaces at all), and nesting this heredoc a second level
          # deeper inside another `#{...}` interpolation (the way `OWNDB`/params
          # above handle conditional template.yaml content) would need its own
          # per-line re-indent pass — one that adds spaces before every line
          # including the already-tab-prefixed recipe ones, corrupting Make's
          # own recipe-line detection. A single top-level heredoc, each line
          # already at its own final indentation (recipe lines as "  \t..." —
          # the same two-space-before-the-tab convention every other recipe
          # line in this Makefile already uses, stripped by the encolosing
          # `<<~MAKE` heredoc's own squiggly stripping below, same as them),
          # sidesteps that: nothing re-touches an already-correct line twice.
          mint_era_recipe =
            if shared
              <<~SHAREDMINT.rstrip
              # NOT AUTOMATED YET for a Shared-mode domain — it has no RDS/VPC
              # of its own to stand a temporary bastion next to (bastion.yaml
              # itself isn't even generated here — bin/project_deploy's own
              # comment on why). Minting era 1 for #{infra_name}'s own schema
              # needs a tunnel to #{owner_domain_name}'s ALREADY-EXISTING RDS
              # instance instead -- reuse #{owner_domain_name}'s own deploy
              # directory's `make mint-era` machinery (or an already-open
              # tunnel to it) to run this domain's own boot against
              # `postgres://...@<tunnel-host>:<port>/#{owner_db_name}` with
              # `schema: #{infra_name.inspect}` in LineageManager.check!'s own
              # settings -- the exact same call this target runs automatically
              # for a domain with its own dedicated instance.
              #
              # IF THIS DOMAIN VENDORS/ATTACHES ANOTHER BLUEBOOK (uses_embryonaut_
              # bluebook, uses_framework), `check!` alone leaves THAT chapter's own
              # aggregates with no snapshot table at all -- it only provisions the
              # ONE bluebook it's called with (era_resolver.rb's own `bluebook.
              # aggregates.each`), never the whole registry. Found live minting
              # lifeadelics' own era: `Payments::Payment.Initiate` refused with
              # "relation \\"payment_head_snapshot_1\\" does not exist" the first
              # time this domain's own checkout route ran for real. The automated
              # (non-Shared) recipe below now does this correctly for every OTHER
              # loaded bluebook, using ONE `Lineage` keyed by THIS domain's own
              # name (never each chapter's own -- a vendored chapter's aggregates
              # share THIS domain's single `hecks_journal_#{infra_name}` and
              # snapshot tables, they do not get a separate journal of their own).
              # Reproduce the same shape manually here: after `LineageManager.
              # check!` returns, `db = PostgresEra.connect_for(bluebook.name,
              # settings)`, `lineage = Lineage.new(db, bluebook.name)`, then for
              # every OTHER loaded bluebook's own aggregates, `lineage.
              # ensure_first_head!(aggregate.storage_name)`.
              #
              # EXIT 0, NOT 1 -- `deploy:`'s own last line (below) always chains
              # `$(MAKE) mint-era` unconditionally, even for a Shared-mode domain,
              # so a nonzero exit here used to mean a fully successful `sam
              # deploy` still left `make deploy` exiting nonzero -- confirmed
              # live: CI and any scripted caller read every Shared-mode deploy as
              # failed, which trains operators to ignore a red `make deploy` on
              # exactly the domains where a real failure most needs to stand out.
              # This step never fails at its own job (it has no automated job to
              # fail at -- it only reports that a manual step remains), so it
              # reports success and leaves the manual-step reminder in the echo
              # text above, not in the exit code. A human running `make mint-era`
              # directly still SEES the same message; they just don't get a
              # misleading "command failed" on top of it either.
              \t@echo "mint-era isn't automated yet for a Shared-mode domain (database \\"Shared\\") -- see this target's own comment in the generated Makefile for the manual path through #{owner_domain_name}'s own tunnel. This is NOT a failure -- exiting 0 so a genuinely successful \\"make deploy\\" still reports success; era-minting for this domain remains a separate manual step."; \\
              \texit 0
              SHAREDMINT
            else
              <<~OWNMINT.rstrip
              \t@echo "Looking up $(STACK)'s VPC/security group..."
              # stack_outputs/bastion_parameters (bin/project_deploy) are the ONE
              # place these OutputKey strings and parameter names live — this eval
              # chain and the --parameter-overrides line just below are both
              # generated from the SAME table template.yaml's Outputs and
              # bastion.yaml's Parameters already read from.
              \t#{stack_outputs.map { |o| %($(eval #{o[:var]} := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --query "Stacks[0].Outputs[?OutputKey=='#{o[:key]}'].OutputValue" --output text))) }.join("\n\t")}
              \t@echo "Deploying the temporary bastion stack $(BASTION_STACK)..."
              \taws cloudformation deploy --template-file bastion.yaml --stack-name $(BASTION_STACK) \\
              \t\t--parameter-overrides #{bastion_parameters.map { |p| "#{p[:name]}=$(#{stack_outputs.find { |o| o[:key] == p[:from_output] }[:var]})" }.join(" ")} \\
              \t\t--capabilities CAPABILITY_IAM
              # ONE continuous shell invocation from here on (every line ends in
              # \\, joining it to the next) — INSTANCE_ID is a SHELL variable, not
              # a Make one: a Make-level $$(eval $$(shell ...)) expands at parse
              # time, BEFORE the `aws cloudformation deploy` line above ever runs,
              # which would make INSTANCE_ID permanently empty. It can only be
              # computed here, after the bastion stack genuinely exists.
              #
              # A COMMENT LINE MUST NEVER SIT BETWEEN TWO \\-CONTINUED RECIPE
              # LINES — confirmed live, the hard way: a `#`-prefixed line inserted
              # between `DB_PASS=...; \\` and the line that used it silently
              # corrupted Make's own assembly of this whole block into one shell
              # script, and `DB_PASS` came out empty on the far side despite
              # printing correctly one line earlier. Every explanatory comment for
              # this whole chain belongs HERE, before it starts, same as this one —
              # never spliced into the middle of it.
              #
              # BASTION TEARDOWN IS PART OF THIS SAME CHAIN, ALL THE WAY THROUGH —
              # a prior version of this recipe ended at `exit $$BOOT_STATUS` with
              # no trailing `\\`, which made Make treat the delete-stack lines
              # after it as a SEPARATE recipe line, reached only on a zero exit.
              # A failed boot (bad tunnel, bad `ruby -e` invocation, anything) left
              # the bastion stack standing forever — including a live 5432 ingress
              # rule punched into the PRODUCTION RDS security group. Teardown now
              # runs unconditionally, with BOOT_STATUS captured up front and
              # returned last, so `make mint-era`'s own exit code still reflects
              # whether era 1 actually got minted.
              #
              # `LineageManager.check!` directly below, NOT `Hecks.boot` — also
              # confirmed live (the very first real invoke: "relation
              # \\"hecks_eras\\" does not exist", despite this step itself
              # reporting success): `Hecks.boot` always dispatches persistence
              # through whatever the domain's OWN .world file declares
              # (`persisted_by("Heki")` for a domain that hasn't opted into
              # Postgres for local dev), by EXPLICIT design — loader.rb's own
              # comment: "persisted_by(\\"PostgresEra\\") is never inferred from
              # anything else." `EraCheck.check!` (what `Hecks.boot` runs) is
              # itself adapter-capability-gated on that same declaration and simply
              # no-ops for a non-lineage-capable adapter — it never touches
              # hecks_eras at all. The fix reuses the SAME loading pipeline
              # `Loader.boot` itself does (`Ports::Loading.bootstrap`/
              # `load_library`/`load_project`/`load_domain`) to build a real,
              # fully-loaded registry (bluebook + any uses_framework attachments),
              # then calls straight into PostgresEra's own `LineageManager.check!`
              # with THIS deploy's actual `DATABASE_URL` — bypassing the world
              # file's own adapter choice entirely, the same targeted pattern
              # spec/adapters/driven/postgres_era/lineage_spec.rb's own `check!` helper
              # already uses.
              #
              # THE WHOLE TUNNEL IS RESTARTED PER ATTEMPT, not just the boot
              # check retried through one long-lived tunnel — confirmed live,
              # the hard way: an SSM port-forwarding session can start and then
              # exit again within the first few seconds (visible in its own log
              # as a session ID that both starts AND exits before the retries
              # even finish), not merely "slow to become ready". Retrying a
              # Postgres connection five times against a tunnel process that has
              # already died is retrying against a corpse — it fails identically
              # every time, for a different reason than the one the retry was
              # built for. Each attempt below kills whatever tunnel the LAST
              # attempt opened (a no-op the first time) and opens a fresh one,
              # so a dead session gets a real replacement, not just more patience.
              #
              # DB_PASS_URLENC, DERIVED RIGHT AFTER DB_PASS BELOW, IS WHAT ACTUALLY
              # GOES INTO THE `postgres://` URL FURTHER DOWN — not DB_PASS itself.
              # RDS/Secrets-Manager-generated passwords are not guaranteed free of
              # `%`, and libpq's own connection-URI parser treats a bare `%` as an
              # invalid token (percent-encoding is the one escape libpq's URI form
              # actually documents and decodes; a raw `%` is not) -- roughly 29% of
              # 32-char generated passwords contain at least one `%`, so this was
              # silently unreachable until it wasn't. `ERB::Util.url_encode`
              # percent-encodes everything outside RFC 3986's unreserved set,
              # exactly what a URI password component needs -- a strict superset
              # of the ExcludeCharacters the Aurora path below already excludes
              # (a no-op there), and the actual fix for the plain-RDS
              # ManageMasterUserPassword path, whose generated character set this
              # template has no control over at all. This comment sits HERE,
              # before the chain starts, on purpose -- see the note further below
              # on why a comment line can never be spliced between two
              # `\`-continued recipe lines.
              \t@INSTANCE_ID=$$(aws cloudformation describe-stacks --stack-name $(BASTION_STACK) --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text); \\
              \techo "Waiting for $$INSTANCE_ID to register with SSM..."; \\
              \tfor i in $$(seq 1 30); do \\
              \t\tSTATUS=$$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null); \\
              \t\tif [ "$$STATUS" = "Online" ]; then break; fi; \\
              \t\tsleep 5; \\
              \tdone; \\
              \tDB_PASS=$$(aws secretsmanager get-secret-value --secret-id $(DB_SECRET_ARN) --query SecretString --output text | ruby -rjson -e 'print JSON.parse(STDIN.read)["password"]'); \\
              \tDB_PASS_URLENC=$$(ruby -rerb -e 'print ERB::Util.url_encode(ARGV[0])' "$$DB_PASS"); \\
              \tBOOT_STATUS=1; \\
              \tfor attempt in 1 2 3 4 5; do \\
              \t\tkill $$TUNNEL_PID 2>/dev/null; \\
              \t\techo "Opening an SSM tunnel to $(DB_HOST):5432 and minting era 1 (attempt $$attempt/5)..."; \\
              \t\taws ssm start-session --target $$INSTANCE_ID \\
              \t\t\t--document-name AWS-StartPortForwardingSessionToRemoteHost \\
              \t\t\t--parameters "{\\"host\\":[\\"$(DB_HOST)\\"],\\"portNumber\\":[\\"5432\\"],\\"localPortNumber\\":[\\"15432\\"]}" \\
              \t\t\t>/tmp/$(BASTION_STACK)-tunnel-$$attempt.log 2>&1 & \\
              \t\tTUNNEL_PID=$$!; \\
              \t\tfor i in $$(seq 1 15); do \\
              \t\t\tnc -z localhost 15432 2>/dev/null && break; \\
              \t\t\tsleep 1; \\
              \t\tdone; \\
              \t\tcd $(ROOT) && DATABASE_URL="postgres://postgres:$$DB_PASS_URLENC@localhost:15432/#{db_name}" ruby -Ilib -e 'require "hecks"; require "hecks/ports/persistence/plugins/era"; loading = Hecks::Ports::Loading.bootstrap; directory = loading.bluebook_directory(ARGV[0]); root = loading.shared_root(nil, directory); registry = Hecks::Runtime::Registry.new(root: File.dirname(directory)); Hecks.with_registry(registry) { loading.load_library; loading.load_project(root); loading.load_domain(directory) }; bluebook = registry.bluebooks[#{declared_domain_name.inspect}] or abort "no #{declared_domain_name} bluebook loaded"; current_text = Hecks::Runtime::EraCheck.source_text_for(bluebook, directory); Hecks::Adapters::PostgresEra::LineageManager.check!(registry: registry, bluebook: bluebook, current_text: current_text, settings: { database: ENV["DATABASE_URL"]#{hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""} }); db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, { database: ENV["DATABASE_URL"]#{hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""} }); lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name); (registry.bluebooks.values - [bluebook]).each { |other| other.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) } }; db.close; puts "booted OK — era resolution ran"' $(DOMAIN) && { BOOT_STATUS=0; break; }; \\
              \t\tBOOT_STATUS=$$?; \\
              \t\techo "boot check attempt $$attempt/5 failed (exit $$BOOT_STATUS) -- restarting the tunnel and retrying in 3s..."; \\
              \t\tsleep 3; \\
              \tdone; \\
              \tkill $$TUNNEL_PID 2>/dev/null; \\
              \techo "Tearing down the temporary bastion stack..."; \\
              \taws cloudformation delete-stack --stack-name $(BASTION_STACK); \\
              \taws cloudformation wait stack-delete-complete --stack-name $(BASTION_STACK); \\
              \techo "$(BASTION_STACK) deleted. Era 1 should now be held if BOOT_STATUS was 0 — verify with bin/console or a Postgres query against hecks_eras."; \\
              \texit $$BOOT_STATUS
              OWNMINT
            end

          # `scaffold-translation`/`translation-audit` — the two-step fix
          # minter.rb's own refusal names ("run bin/scaffold_translation to write
          # the edge, check it with bin/translation_audit, then boot again") when
          # a deploy's own pre-flight boot check refuses a shape change with no
          # translation edge covering it. Same bastion/tunnel/retry/teardown
          # chain mint_era_recipe already uses — only the one thing done over the
          # tunnel differs: these run the scaffold/audit scripts (hecks's
          # own bin/, not a Ruby -e one-liner) instead of a boot check, since
          # both scripts already do their own registry-loading internally.
          #
          # HECKS_SCHEMA/DATABASE_URL below are not actually consumed by those
          # scripts, despite reading as if they were: grep-confirmed, neither
          # `bin/scaffold_translation` nor `bin/translation_audit` nor
          # `Hecks::Bluebook::Behaviour::World#for_binding` nor
          # `PostgresEra.connect_for` ever reads `ENV["DATABASE_URL"]` or
          # `ENV["HECKS_SCHEMA"]` — both scripts call
          # `registry.world(bluebook.name)&.for_binding(...)`, a pure hash lookup
          # against whatever literal `database "..."` string #{domain}'s own
          # `.world` file declares. Without `db_env_blind:` below, this whole
          # recipe would stand up a real bastion, punch a live 5432 ingress rule
          # into production's security group, open a real SSM tunnel to
          # #{stack_name}'s RDS instance, tear it all down again — and then
          # silently scaffold/audit the developer's local dev database the
          # entire time, reporting success. `db_env_blind:`
          # (below) is exactly this: true for scaffold-translation/
          # translation-audit (confirmed env-blind), left false for
          # migrate-console-settings (an app-owned script this generator doesn't
          # control the internals of — it may honor these vars; not asserting
          # either way here). A `db_env_blind` recipe refuses before ever
          # touching AWS unless `ALLOW_LOCAL_DB=1` is set, rather than silently
          # doing the wrong (but locally successful-looking) thing.
          # `cwd:`/`run_prefix:` — every existing caller runs a hecks-owned
          # script from hecks's own $(root) with `-Ilib` (source, not the
          # installed gem); `migrate_console_settings_recipe` below is the one
          # exception, an app-owned script that needs the app's own Gemfile
          # context instead — `cd $(DOMAIN) && bundle exec ruby`, not `-Ilib`.
          translation_recipe = lambda do |verb, script, extra_args = "", cwd: "$(ROOT)", run_prefix: "ruby -Ilib", db_env_blind: false|
            if shared
              <<~SHAREDTRANSLATION.rstrip
              \t@echo "#{verb} isn't automated yet for a Shared-mode domain (database \\"Shared\\") -- see mint-era's own comment in the generated Makefile for the manual path through #{owner_domain_name}'s own tunnel."; \\
              \texit 1
              SHAREDTRANSLATION
            else
              <<~OWNTRANSLATION.rstrip
              #{db_env_blind ? <<~ENVBLINDGUARD.rstrip
              \t@if [ -z "$$ALLOW_LOCAL_DB" ]; then \\
              \t\techo "REFUSING: #{script} resolves its OWN database connection from #{domain}'s .world file, NOT from DATABASE_URL/HECKS_SCHEMA -- opening a real tunnel to #{stack_name}'s production RDS instance below would silently scaffold/audit the LOCAL dev database instead and report success (see this recipe's own comment, above, for the confirmed root cause). Set ALLOW_LOCAL_DB=1 to run #{verb} against #{domain}'s local .world-declared database on purpose (e.g. to exercise the scaffold/audit logic itself); otherwise run this for real against production via the manual tunnel path mint-era's own comment describes."; \\
              \t\texit 1; \\
              \tfi
              ENVBLINDGUARD
              : ""}
              \t@echo "Looking up $(STACK)'s VPC/security group..."
              \t#{stack_outputs.map { |o| %($(eval #{o[:var]} := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --query "Stacks[0].Outputs[?OutputKey=='#{o[:key]}'].OutputValue" --output text))) }.join("\n\t")}
              \t@echo "Deploying the temporary bastion stack $(BASTION_STACK)..."
              \taws cloudformation deploy --template-file bastion.yaml --stack-name $(BASTION_STACK) \\
              \t\t--parameter-overrides #{bastion_parameters.map { |p| "#{p[:name]}=$(#{stack_outputs.find { |o| o[:key] == p[:from_output] }[:var]})" }.join(" ")} \\
              \t\t--capabilities CAPABILITY_IAM
              # DB_PASS_URLENC -- same percent-encoding fix as mint_era_recipe's
              # own comment above the equivalent line in that recipe (libpq's URI
              # parser rejects a bare `%`, which a generated RDS password isn't
              # guaranteed to be free of); this recipe's DATABASE_URL below uses
              # the encoded form for the same reason, even though the script it
              # feeds doesn't currently read it (see db_env_blind above).
              \t@INSTANCE_ID=$$(aws cloudformation describe-stacks --stack-name $(BASTION_STACK) --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text); \\
              \techo "Waiting for $$INSTANCE_ID to register with SSM..."; \\
              \tfor i in $$(seq 1 30); do \\
              \t\tSTATUS=$$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null); \\
              \t\tif [ "$$STATUS" = "Online" ]; then break; fi; \\
              \t\tsleep 5; \\
              \tdone; \\
              \tDB_PASS=$$(aws secretsmanager get-secret-value --secret-id $(DB_SECRET_ARN) --query SecretString --output text | ruby -rjson -e 'print JSON.parse(STDIN.read)["password"]'); \\
              \tDB_PASS_URLENC=$$(ruby -rerb -e 'print ERB::Util.url_encode(ARGV[0])' "$$DB_PASS"); \\
              \tRUN_STATUS=1; \\
              \tfor attempt in 1 2 3 4 5; do \\
              \t\tkill $$TUNNEL_PID 2>/dev/null; \\
              \t\techo "Opening an SSM tunnel to $(DB_HOST):5432 and running #{verb} (attempt $$attempt/5)..."; \\
              \t\taws ssm start-session --target $$INSTANCE_ID \\
              \t\t\t--document-name AWS-StartPortForwardingSessionToRemoteHost \\
              \t\t\t--parameters "{\\"host\\":[\\"$(DB_HOST)\\"],\\"portNumber\\":[\\"5432\\"],\\"localPortNumber\\":[\\"15432\\"]}" \\
              \t\t\t>/tmp/$(BASTION_STACK)-tunnel-$$attempt.log 2>&1 & \\
              \t\tTUNNEL_PID=$$!; \\
              \t\tfor i in $$(seq 1 15); do \\
              \t\t\tnc -z localhost 15432 2>/dev/null && break; \\
              \t\t\tsleep 1; \\
              \t\tdone; \\
              \t\tcd #{cwd} && DATABASE_URL="postgres://postgres:$$DB_PASS_URLENC@localhost:15432/#{db_name}" HECKS_SCHEMA="#{hecks_schema}" #{run_prefix} #{script} #{cwd == "$(ROOT)" ? "$(DOMAIN) " : ""}#{extra_args}&& { RUN_STATUS=0; break; }; \\
              \t\tRUN_STATUS=$$?; \\
              \t\techo "#{verb} attempt $$attempt/5 failed (exit $$RUN_STATUS) -- restarting the tunnel and retrying in 3s..."; \\
              \t\tsleep 3; \\
              \tdone; \\
              \tkill $$TUNNEL_PID 2>/dev/null; \\
              \techo "Tearing down the temporary bastion stack..."; \\
              \taws cloudformation delete-stack --stack-name $(BASTION_STACK); \\
              \taws cloudformation wait stack-delete-complete --stack-name $(BASTION_STACK); \\
              \techo "$(BASTION_STACK) deleted."; \\
              \texit $$RUN_STATUS
              OWNTRANSLATION
            end
          end

          scaffold_translation_recipe = translation_recipe.call("scaffold-translation", "bin/scaffold_translation", db_env_blind: true)
          translation_audit_recipe = translation_recipe.call("translation-audit", "bin/translation_audit", db_env_blind: true)

          # `make migrate-console-settings` — the same bastion/tunnel/retry/
          # teardown chain as scaffold-translation/translation-audit, running an
          # app-owned one-time migration script instead of one of hecks's
          # own bin/ tools (see translation_recipe's own `cwd:`/`run_prefix:`
          # comment). Only meaningful for a domain that actually has one — most
          # domains don't, so this target is generated unconditionally but simply
          # has nothing to run for them; harmless (`bundle exec ruby` on a
          # missing file just fails loudly, same as any other missing script
          # would).
          migrate_console_settings_recipe = translation_recipe.call(
            "migrate-console-settings", "bin/migrate_console_settings", "",
            cwd: "$(DOMAIN)", run_prefix: "bundle exec ruby"
          )

          # `rename-schema`'s own recipe body — same top-level-variable-not-inlined
          # reasoning as `mint_era_recipe` just above (recipe lines need a literal
          # leading tab; nesting this heredoc a level deeper would need its own
          # re-indent pass). Reuses the same bastion.yaml, the same stack/
          # BASTION_STACK Make variables mint-era already defines, and the same
          # stand-up/tunnel/teardown-no-matter-what shell chain — only the one
          # thing done over the tunnel differs: a schema rename instead of a
          # Ruby boot. `OLD`/`NEW` are Make command-line variables
          # (`make rename-schema OLD=old NEW=new`), not baked in here, so this
          # is genuinely reusable — the domain whose own schema this renames is
          # whichever one owns this stack's RDS instance (this generator's own
          # `#{infra_name}` database on it), not necessarily this domain forever.
          #
          # Idempotent by inspection, not by catching a Postgres error: checks
          # which of old/new actually exists as a schema before touching
          # anything, so a second run (or a run after a partial failure) reads
          # as a clear no-op message rather than a bare "schema already exists"
          # error with no context.
          rename_schema_recipe =
            if shared
              <<~SHAREDRENAME.rstrip
              # NOT AUTOMATED for a Shared-mode domain, same reason mint-era
              # isn't: there is no bastion.yaml here to stand up next to (this
              # domain has no RDS/VPC of its own). This domain's own schema
              # lives inside #{owner_domain_name}'s database — run this same
              # target from #{owner_domain_name}'s own deploy directory instead.
              \t@echo "rename-schema isn't automated for a Shared-mode domain (database \\"Shared\\") -- run it from #{owner_domain_name}'s own deploy directory instead, which owns the RDS instance this domain's schema actually lives on."; \\
              \texit 1
              SHAREDRENAME
            else
              <<~OWNRENAME.rstrip
              # THE WHOLE TUNNEL IS RESTARTED PER ATTEMPT, not just probed once
              # through a single long-lived session — confirmed live, the hard
              # way: an SSM port-forwarding session can start and then exit
              # again within seconds, not merely "slow to become ready". Probing
              # the same dead tunnel five times fails identically every time,
              # for a different reason than the retry was built for. Without
              # this restart, a still-dead tunnel also doesn't just fail loudly
              # — `EXISTS_OLD`/`EXISTS_NEW` would both come back empty, which the
              # branch below reads as "neither schema exists" and reports as if
              # that were the real answer, not a connectivity failure wearing
              # its name — which is exactly why `TUNNEL_READY` gates that branch
              # explicitly rather than trusting empty results at face value.
              #
              # OLD/NEW ARE ALLOWLISTED AS BARE IDENTIFIERS, not SQL-escaped, before
              # either one reaches a psql command line: both get interpolated
              # straight into the `nspname = '...'` lookups above and the
              # `ALTER SCHEMA "..." RENAME TO "..."` below, and a schema name can't
              # be bound as a parameter the way a value can — quoting/escaping an
              # identifier is exactly the kind of thing that's easy to get subtly
              # wrong, so instead of trying, this refuses anything that isn't
              # `^[A-Za-z_][A-Za-z0-9_]*$` outright. `make` runs this recipe as an
              # operator command, not user-facing web input, but it still executes
              # against production RDS, so a typo'd or copy-pasted `OLD`/`NEW`
              # containing quotes or `;` must fail loudly here, before either
              # tunnel or query, rather than run as-is.
              #
              # `$$OLD`/`$$NEW` HERE, NOT `$(OLD)`/`$(NEW)`: this check itself has
              # to read the value without Make ever splicing its raw text into the
              # recipe line, or a value containing `;`/`"` would break out of THIS
              # line's shell command and run before the pattern match ever sees it
              # — confirmed live, the same way the tunnel-restart behavior above
              # was. `$$OLD` instead reads the real shell environment variable
              # `make` already exports for command-line-assigned vars, so the
              # value is one opaque string to the shell no matter what characters
              # it contains. Once a value's passed this gate it's provably just
              # `[A-Za-z0-9_]`, so the existing `$(OLD)`/`$(NEW)` splices further
              # below (already written before this fix, reused as-is) are safe.
              \t@[ -n "$$OLD" ] && [ -n "$$NEW" ] || { echo "usage: make rename-schema OLD=<old-schema> NEW=<new-schema>"; exit 1; }
              \t@echo "$$OLD" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$$' || { echo "invalid OLD schema name -- schema names must match ^[A-Za-z_][A-Za-z0-9_]*$$, refusing to touch SQL"; exit 1; }
              \t@echo "$$NEW" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$$' || { echo "invalid NEW schema name -- schema names must match ^[A-Za-z_][A-Za-z0-9_]*$$, refusing to touch SQL"; exit 1; }
              \t@echo "Looking up $(STACK)'s VPC/security group..."
              \t#{stack_outputs.map { |o| %($(eval #{o[:var]} := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --query "Stacks[0].Outputs[?OutputKey=='#{o[:key]}'].OutputValue" --output text))) }.join("\n\t")}
              \t@echo "Deploying the temporary bastion stack $(BASTION_STACK)..."
              \taws cloudformation deploy --template-file bastion.yaml --stack-name $(BASTION_STACK) \\
              \t\t--parameter-overrides #{bastion_parameters.map { |p| "#{p[:name]}=$(#{stack_outputs.find { |o| o[:key] == p[:from_output] }[:var]})" }.join(" ")} \\
              \t\t--capabilities CAPABILITY_IAM
              \t@INSTANCE_ID=$$(aws cloudformation describe-stacks --stack-name $(BASTION_STACK) --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text); \\
              \techo "Waiting for $$INSTANCE_ID to register with SSM..."; \\
              \tfor i in $$(seq 1 30); do \\
              \t\tSTATUS=$$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null); \\
              \t\tif [ "$$STATUS" = "Online" ]; then break; fi; \\
              \t\tsleep 5; \\
              \tdone; \\
              \tDB_PASS=$$(aws secretsmanager get-secret-value --secret-id $(DB_SECRET_ARN) --query SecretString --output text | ruby -rjson -e 'print JSON.parse(STDIN.read)["password"]'); \\
              \tTUNNEL_READY=1; \\
              \tfor attempt in 1 2 3 4 5; do \\
              \t\tkill $$TUNNEL_PID 2>/dev/null; \\
              \t\techo "Opening an SSM tunnel to $(DB_HOST):5432 (attempt $$attempt/5)..."; \\
              \t\taws ssm start-session --target $$INSTANCE_ID \\
              \t\t\t--document-name AWS-StartPortForwardingSessionToRemoteHost \\
              \t\t\t--parameters "{\\"host\\":[\\"$(DB_HOST)\\"],\\"portNumber\\":[\\"5432\\"],\\"localPortNumber\\":[\\"15432\\"]}" \\
              \t\t\t>/tmp/$(BASTION_STACK)-tunnel-$$attempt.log 2>&1 & \\
              \t\tTUNNEL_PID=$$!; \\
              \t\tfor i in $$(seq 1 15); do \\
              \t\t\tnc -z localhost 15432 2>/dev/null && break; \\
              \t\t\tsleep 1; \\
              \t\tdone; \\
              \t\tPGPASSWORD=$$DB_PASS psql -h localhost -p 15432 -U postgres -d #{db_name} -tAc "SELECT 1" >/dev/null 2>&1 && { TUNNEL_READY=0; break; }; \\
              \t\techo "tunnel not carrying real traffic yet (attempt $$attempt/5) -- restarting the tunnel and retrying in 3s..."; \\
              \t\tsleep 3; \\
              \tdone; \\
              \tEXISTS_OLD=$$(PGPASSWORD=$$DB_PASS psql -h localhost -p 15432 -U postgres -d #{db_name} -tAc "SELECT 1 FROM pg_namespace WHERE nspname = '$(OLD)'"); \\
              \tEXISTS_NEW=$$(PGPASSWORD=$$DB_PASS psql -h localhost -p 15432 -U postgres -d #{db_name} -tAc "SELECT 1 FROM pg_namespace WHERE nspname = '$(NEW)'"); \\
              \tif [ "$$TUNNEL_READY" != "0" ]; then \\
              \t\techo "tunnel never carried a real connection -- aborting without touching either schema"; \\
              \t\tBOOT_STATUS=1; \\
              \telif [ "$$EXISTS_NEW" = "1" ]; then \\
              \t\techo "schema $(NEW) already exists -- already renamed, no-op"; \\
              \t\tBOOT_STATUS=0; \\
              \telif [ "$$EXISTS_OLD" = "1" ]; then \\
              \t\tPGPASSWORD=$$DB_PASS psql -h localhost -p 15432 -U postgres -d #{db_name} -v ON_ERROR_STOP=1 -c "ALTER SCHEMA \\"$(OLD)\\" RENAME TO \\"$(NEW)\\""; \\
              \t\tBOOT_STATUS=$$?; \\
              \t\techo "renamed schema $(OLD) to $(NEW) (exit $$BOOT_STATUS)"; \\
              \telse \\
              \t\techo "neither schema $(OLD) nor $(NEW) exists on #{db_name} -- nothing to rename"; \\
              \t\tBOOT_STATUS=1; \\
              \tfi; \\
              \tkill $$TUNNEL_PID 2>/dev/null; \\
              \techo "Tearing down the temporary bastion stack..."; \\
              \taws cloudformation delete-stack --stack-name $(BASTION_STACK); \\
              \taws cloudformation wait stack-delete-complete --stack-name $(BASTION_STACK); \\
              \techo "$(BASTION_STACK) deleted."; \\
              \texit $$BOOT_STATUS
              OWNRENAME
            end

          # `deploy:`'s own `sam deploy` call — `google_oauth_present` and
          # `shared` are collected together here rather than spelled as an
          # if/elsif/else, the same shape `Parameters:` above holds to: the
          # two are independent facts about a domain, not alternatives, and
          # lifeadelics is both — an elsif shape would silently drop the
          # Owning* overrides whenever OAuth is also present. Caught live
          # the first time a Shared-mode domain with real Google OAuth
          # actually ran `make deploy`: `sam deploy` refused
          # with "Parameters: [OwningVpcId, ...] must have values" because
          # nothing had ever passed them. WebRedirectBaseUrl stays a conditional
          # override (empty on a genuine first deploy, before the Function Url
          # exists — see that Parameter's own comment); Owning* is unconditional
          # whenever `shared`, in every branch that reaches `sam deploy` at all.
          # One continuous `\`-joined shell chain, however many pieces
          # contribute to it — `@` (Make's own "don't echo this line" prefix)
          # is only meaningful on the true first line of that chain; written on
          # any later line it stops being a Make directive at all and becomes
          # literal shell text (`@WEB_URL=...` parses as a bogus command, not
          # an assignment) the moment two independently-`@`-prefixed pieces
          # get concatenated. Built unprefixed here; `@` is added once, to
          # whichever piece actually ends up first, right before joining.
          owner_lookup_lines = shared ? [
            %(OWNER_VPC_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text); \\),
            %(OWNER_SUBNET_A_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetAId'].OutputValue" --output text); \\),
            %(OWNER_SUBNET_B_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetBId'].OutputValue" --output text); \\),
            %(OWNER_SG_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='FunctionSecurityGroupId'].OutputValue" --output text); \\),
            %(OWNER_DB_HOST=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='DatabaseEndpoint'].OutputValue" --output text); \\),
            %(OWNER_DB_SECRET_ARN=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query "Stacks[0].Outputs[?OutputKey=='DatabaseSecretArn'].OutputValue" --output text); \\),
          ] : []
          owning_overrides = "OwningVpcId=$$OWNER_VPC_ID OwningSubnetAId=$$OWNER_SUBNET_A_ID OwningSubnetBId=$$OWNER_SUBNET_B_ID OwningSecurityGroupId=$$OWNER_SG_ID OwningDatabaseEndpoint=$$OWNER_DB_HOST OwningDatabaseSecretArn=$$OWNER_DB_SECRET_ARN"

          sam_deploy_lines =
            if google_oauth_present && shared
              [
                %(WEB_URL=$$(aws lambda get-function-url-config --function-name #{rust_web ? stack_name : "#{stack_name}-web"} --query FunctionUrl --output text 2>/dev/null | sed 's:/$$::'); \\),
                "if [ -n \"$$WEB_URL\" ]; then \\",
                %(\tsam deploy --parameter-overrides WebRedirectBaseUrl="$$WEB_URL" #{owning_overrides}; \\),
                "else \\",
                "\tsam deploy --parameter-overrides #{owning_overrides}; \\",
                "fi",
              ]
            elsif google_oauth_present
              [
                %(WEB_URL=$$(aws lambda get-function-url-config --function-name #{rust_web ? stack_name : "#{stack_name}-web"} --query FunctionUrl --output text 2>/dev/null | sed 's:/$$::'); \\),
                "if [ -n \"$$WEB_URL\" ]; then \\",
                %(\tsam deploy --parameter-overrides WebRedirectBaseUrl="$$WEB_URL"; \\),
                "else \\",
                "\tsam deploy; \\",
                "fi",
              ]
            elsif shared
              ["sam deploy --parameter-overrides #{owning_overrides}"]
            else
              ["sam deploy"]
            end

          deploy_shell_chain = owner_lookup_lines + sam_deploy_lines
          deploy_shell_chain = ["@#{deploy_shell_chain.first}"] + deploy_shell_chain.drop(1) if deploy_shell_chain.first&.match?(/=\$\$\(/)

          # `deploy:`'s own pre-deploy `mint-era` bridge (below, inlined into
          # `PREDEPLOYBRIDGE`) — a plain Ruby string built here, not inlined
          # directly in that heredoc, for the same reason as everywhere else
          # comment: it needs its own `if/else` branch on `google_oauth_present`,
          # and Ruby heredoc-in-string-interpolation only reads cleanly one level
          # deep before it gets hard to follow.
          #
          # Google OAuth newly added to an existing stack deadlocks this bridge —
          # confirmed live: stack_outputs (above) only gains PublicSubnetId/
          # BastionSubnetId entries once `google_oauth_present` is true, but those
          # two CloudFormation resources (#{db_id}PublicSubnet/
          # #{db_id}BastionPublicSubnet) don't exist on a stack that predates
          # turning OAuth on — only the upcoming `sam deploy` (further below,
          # still ahead of us here) creates them. This pre-check's own `mint-era`
          # call evaluates stack_outputs against the currently live stack (an
          # `aws cloudformation describe-stacks` eval chain, same one mint-era's
          # own recipe uses), gets an empty string back for both, and hands
          # bastion.yaml an empty `AWS::EC2::Subnet::Id` — CloudFormation refuses
          # that outright. The pre-check fails before `sam deploy` ever runs, so
          # the one deploy that would actually create those outputs never gets
          # the chance to: a hard deadlock, `make deploy` can never get OAuth
          # provisioned on a stack that didn't have it already. Detected the same
          # way a genuine first deploy is detected just below (describe-stacks
          # succeeding or not) — here, describe-stacks succeeds (the stack
          # itself exists) but the specific output this deploy is newly adding
          # does not, yet. Skip the pre-deploy bridge in exactly that one case;
          # the unconditional `mint-era` call at the very end of `deploy:` still
          # covers it once `sam deploy` has actually created PublicSubnetId/
          # BastionSubnetId — the exact same "runs once, after the stack exists"
          # path a domain's true first deploy already takes below.
          predeploy_bridge_shell =
            if google_oauth_present
              <<~OAUTHBRIDGE.rstrip
              @echo "Checking whether $(STACK) already exists, and if so whether it already has Google OAuth's PublicSubnetId/BastionSubnetId outputs, before deciding whether to bridge era history now or let this deploy create them first..."
              @if aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null 2>&1; then \\
              \tOAUTH_OUTPUTS_READY=$$(aws cloudformation describe-stacks --stack-name $(STACK) --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetId'].OutputValue" --output text 2>/dev/null); \\
              \tif [ -z "$$OAUTH_OUTPUTS_READY" ]; then \\
              \t\techo "Existing stack found, but Google OAuth is newly being added -- PublicSubnetId/BastionSubnetId don't exist on it yet (sam deploy, below, is what creates them); skipping the pre-deploy bridge this one time so THIS deploy can actually run. mint-era still runs once, after sam deploy, same as a genuine first deploy."; \\
              \telse \\
              \t\techo "Existing stack found -- bridging era history before this deploy flips $(STACK) over, not after."; \\
              \t\t$(MAKE) mint-era || exit 1; \\
              \tfi; \\
              else \\
              \techo "No existing stack -- first deploy, nothing to bridge yet; mint-era runs once, below, after the stack (and its RDS instance) exist."; \\
              fi
              OAUTHBRIDGE
            else
              <<~PLAINBRIDGE.rstrip
              @echo "Checking whether $(STACK) already exists, to decide whether this deploy needs to bridge era history before it flips the stack over..."
              @if aws cloudformation describe-stacks --stack-name $(STACK) >/dev/null 2>&1; then \\
              \techo "Existing stack found -- bridging era history before this deploy flips $(STACK) over, not after."; \\
              \t$(MAKE) mint-era || exit 1; \\
              else \\
              \techo "No existing stack -- first deploy, nothing to bridge yet; mint-era runs once, below, after the stack (and its RDS instance) exist."; \\
              fi
              PLAINBRIDGE
            end

          deploy_recipe_lines = (
            (google_oauth_present ? ["$(MAKE) sync-google-oauth"] : []) +
            (shared ? [%(@echo "Looking up #{owner_stack_name}'s shared VpcId/PrivateSubnetAId/PrivateSubnetBId/FunctionSecurityGroupId/DatabaseEndpoint/DatabaseSecretArn outputs to pass as $(STACK)'s Owning* parameters...")] : []) +
            deploy_shell_chain
          ).map { |l| "\t#{l}" }.join("\n")

          makefile_content = <<~MAKE
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
            # this file rather than hand-editing.
            #
            # `sam build` invokes the build-<LogicalId> target below (SAM's own
            # BuildMethod: makefile convention — see template.yaml's Metadata).
            # `cargo lambda` (https://www.cargo-lambda.info) cross-compiles
            # rust/host for arm64 Lambda without Docker or a hand-configured
            # cross-linker — install once with `pip3 install cargo-lambda` or
            # `brew install cargo-lambda`.

            HOST_DIR := #{File.join(root, "rust", "host")}
            # `domain_name`, matching bin/project_wasm's own target_mod_name
            # (a Rust-build-pipeline naming convention, not AWS resource
            # identity — see HECKS_WASM_PATH's own comment above).
            WASM     := #{File.join(root, "rust", "dist", "#{domain_name}.wasm")}

            build-#{logical_id}:
            \t@command -v cargo-lambda >/dev/null 2>&1 || { \\
            \t\techo "cargo-lambda isn't installed. Install it once with: pip3 install cargo-lambda"; \\
            \t\texit 1; \\
            \t}
            # ALWAYS rebuilt, never `test -f $(WASM) || ...` — that guard only
            # checked EXISTENCE, not staleness, so a wasm built once at the
            # start of a work session silently kept getting deployed through
            # every later kernel change (a real, live bug: this cost a stale
            # deploy against a wasm that predated the kernel's own "mutations"
            # field). `bin/project_wasm` recompiles fast enough that "always
            # rebuild" is the safe default, matching rust/host's own bootstrap
            # build just below, which was never guarded this way to begin with.
            \tcd #{root} && bin/project_wasm #{domain}
            \t@rustup target list --installed 2>/dev/null | grep -qx aarch64-unknown-linux-gnu || rustup target add aarch64-unknown-linux-gnu
            # `rustup run stable`, not a bare `cargo lambda` — same reasoning
            # bin/project_wasm's own Makefile-equivalent line holds itself to: a
            # `cargo`/`rustc` earlier on PATH than rustup's own shims (Homebrew
            # installs one; common on this kind of machine) is a DIFFERENT
            # toolchain that never saw `rustup target add`, and fails with
            # "can't find crate for \`core\`" for the cross target even though
            # `rustup target list --installed` reports it present.
            # macOS -> Linux arm64 cross-compiling by default routes through
            # zig (cargo-lambda's own bundled cargo-zigbuild) — every zig
            # release checked so far (0.15.2, 0.16.0) rejects
            # `-Wl,--fix-cortex-a53-843419`, a flag rustc's own
            # aarch64-unknown-linux-gnu target emits unconditionally: "error:
            # unsupported linker arg: --fix-cortex-a53-843419", found live on
            # THIS domain's own very first real deploy attempt (upstream:
            # https://github.com/ziglang/zig/issues, no fix released yet as of
            # this comment). Not fixable by a flag here — it's zig's own `zig
            # cc` argument-translation layer refusing before rustc's link step
            # ever runs. If this build fails with that error, cargo-lambda has
            # a real, documented non-zig, non-Docker fallback: `-c cargo` (or
            # `CARGO_LAMBDA_COMPILER=cargo`) plus a real GNU cross-toolchain —
            # `brew tap messense/macos-cross-toolchains && brew install
            # aarch64-unknown-linux-gnu` (this flag has worked in real
            # binutils/LLD since 2018; only zig's own translation of it is the
            # gap), then set `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=
            # aarch64-linux-gnu-gcc` with that toolchain's own bin/ on PATH.
            # Confirmed working end to end (a real `sam deploy` against a real
            # Lambda) the same day this comment was written.
            \tcd $(HOST_DIR) && rustup run stable cargo lambda build --release --arm64
            \tcp $(HOST_DIR)/target/lambda/bootstrap/bootstrap $(ARTIFACTS_DIR)/bootstrap
            \tcp $(WASM) $(ARTIFACTS_DIR)/#{domain_name}.wasm#{rust_web ? %(\n\tcp #{File.join(root, "rust", "dist", "#{domain_name}.ir.json")} $(ARTIFACTS_DIR)/#{domain_name}.ir.json) : ""}

            # `sam build <resource>` WIPES .aws-sam/build/ entirely before
            # building just the one resource named -- confirmed live: building
            # #{web_logical_id} second left NO #{logical_id}/ directory behind at
            # all, and reverted its OWN built CodeUri back to the raw, unbuilt
            # source value ("../.." -- CodeUri: . resolved two directories up
            # from .aws-sam/build/template.yaml). `sam deploy` then zips THAT
            # directory verbatim as #{logical_id}'s own code -- a real, live
            # deploy shipped #{web_logical_id}'s own source tree (Gemfile,
            # lambda_handler.rb, even .env.local) as #{logical_id}'s Lambda
            # package this way, caught by downloading the actually-deployed
            # code and finding #{web_logical_id}'s file tree inside it.
            # `deploy:`'s own two separate `sam build <resource>` calls can
            # never both survive in .aws-sam/build/ at once — this target
            # re-populates #{logical_id}'s build directory from the SAME
            # already-built bootstrap+wasm build-#{logical_id} just produced
            # (untouched by the second sam build call — only .aws-sam/build/
            # itself gets wiped, never $(HOST_DIR)/target or $(WASM)) and
            # repoints the built template's CodeUri back at it.
            .PHONY: restore-#{logical_id}-build
            restore-#{logical_id}-build:
            \t@mkdir -p .aws-sam/build/#{logical_id}
            \tcp $(HOST_DIR)/target/lambda/bootstrap/bootstrap .aws-sam/build/#{logical_id}/bootstrap
            \tcp $(WASM) .aws-sam/build/#{logical_id}/#{domain_name}.wasm#{rust_web ? %(\n\tcp #{File.join(root, "rust", "dist", "#{domain_name}.ir.json")} .aws-sam/build/#{logical_id}/#{domain_name}.ir.json) : ""}
            \truby -e 'lines = File.readlines(".aws-sam/build/template.yaml"); start = lines.index { |l| l.strip == "#{logical_id}:" } or raise "restore-#{logical_id}-build: #{logical_id} resource not found in built template"; idx = (start+1...lines.length).find { |i| lines[i] =~ /CodeUri:/ } or raise "restore-#{logical_id}-build: no CodeUri line found under #{logical_id}"; lines[idx] = lines[idx].sub(/CodeUri:.*/, "CodeUri: #{logical_id}"); File.write(".aws-sam/build/template.yaml", lines.join)'

            # `make verify-parity-#{logical_id}` — closes the exact gap the
            # equivalence-gap plan's own Phase 8 named: parity was checked ONLY
            # against CI's fixed test corpus, completely decoupled from what a
            # real `sam deploy` actually ships — `bin/rust_conformance` (the
            # differential harness, docs/decisions/0010-ruby-is-the-reference-
            # implementation.md) had never once been run against a specific
            # compiled deploy artifact. Runs it here, for real, against
            # $(WASM) -- the EXACT file `build-#{logical_id}` (above) just built
            # and `deploy:` (below) is about to ship -- not a corpus-wide `cargo
            # build`'s own separate binary. `bin/rust_conformance` exits non-zero
            # on any mismatch, which this target lets propagate uncaught: a real
            # divergence between THIS artifact and Ruby's own reading of the
            # identical source blocks `make deploy` before `sam deploy` ever
            # runs, the same way a failing build already would.
            #
            # `spec/corpus/#{domain_name}.json` is this domain's OWN pinned
            # fuzzer-replay script (the same shape `bin/fuzz`/`bin/run` already
            # use) -- if a domain doesn't have one yet, this warns LOUDLY and
            # continues rather than either silently skipping (this project's own
            # standing rule against a silent gap reading as full coverage) or
            # blocking every deploy of a domain nobody has written one for yet.
            #
            # SECOND HALF, BELOW — `bin/rust_conformance_fuzz`, ADR 0037's own fuzz
            # bridge pointed at this exact $(WASM). A pinned script only proves
            # "matches Ruby on the cases we thought to write down" (ADR 0039's own
            # honest framing); the fuzz bridge is what actually FOUND Findings 1-6.
            # Deliberately WARN-ONLY (`-@`, not `@`) for now: ADR 0037 already
            # catalogues real, confirmed, not-yet-fixed divergences (Findings 3 and
            # 5) that fire on ordinary generated sequences for more than one real
            # domain today, so making this a hard blocker before those are closed
            # would turn every affected domain's `make deploy` red for a reason
            # this target can't yet point at a fix for. Flip `-@` to `@` once ADR
            # 0037's open findings are closed and this stops firing in practice.
            .PHONY: verify-parity-#{logical_id}
            verify-parity-#{logical_id}:
            \t@if [ -f #{root}/spec/corpus/#{domain_name}.json ]; then \\
            \t\tcd #{root} && bin/rust_conformance #{domain} spec/corpus/#{domain_name}.json $(WASM); \\
            \telse \\
            \t\techo "verify-parity-#{logical_id}: no spec/corpus/#{domain_name}.json -- SKIPPING the pre-deploy Ruby/Rust parity check, nothing to compare $(WASM) against. Write one (bin/fuzz/bin/run's own script shape) before this domain's next deploy."; \\
            \tfi
            \t@echo "verify-parity-#{logical_id}: fuzzing $(WASM) against generated sequences (ADR 0037's bridge, WARN-ONLY -- see this target's own comment)..."
            \t-@cd #{root} && bin/rust_conformance_fuzz #{domain} $(WASM)

            # `make mint-era` — takes #{stack_name}'s RDS instance from freshly
            # created to "era 1 minted, ready for HECKS_DOMAIN/HECKS_ERA to
            # resolve" (template.yaml's own env vars already assume era 1 —
            # this is what makes that true). Run ONCE per fresh database, before
            # the first real `sam deploy` of the Lambda itself; safe to re-run
            # (a second boot against an already-held era 1 is a no-op — see
            # era_resolver.rb's own quiet-reboot branch). Stands up bastion.yaml
            # as its own sibling stack, uses it for one Ruby boot over an SSM
            # tunnel, then deletes it — nothing from this target is left running
            # afterward.
            ROOT      := #{root}
            DOMAIN    := #{domain}
            STACK     := #{stack_name}
            BASTION_STACK := #{stack_name}-bastion

            mint-era:
            #{mint_era_recipe}

            # `make scaffold-translation` — run this when a deploy's own
            # pre-flight boot check (or `make mint-era` directly) refuses with
            # "the shape changed (era N) and no translation edge covers it".
            # Diffs the held era against the current bluebook over the same
            # bastion tunnel mint-era uses and WRITES a translations/*.bluebook
            # edge file into this domain's own repo — confident rules inline,
            # genuine ambiguities as `unresolved` lines a human has to resolve by
            # hand (a rename, a drop, a compute — never guessed). Review the
            # written file, then `make translation-audit`.
            scaffold-translation:
            #{scaffold_translation_recipe}

            # `make translation-audit` — verifies a written (or still-pending)
            # translation edge over the same tunnel: every translated state
            # against the new era's own types/invariants/lifecycle, the compiled
            # SQL against the port's own reference transform, and a before/after
            # sample of real records printed for human review. Re-run
            # `make deploy` (or `make mint-era`) once this passes — that's what
            # actually applies the edge; this only checks it.
            translation-audit:
            #{translation_audit_recipe}

            # `make migrate-console-settings` — runs this domain's own
            # bin/migrate_console_settings (if it has one) over the same bastion
            # tunnel every other Postgres-touching target here uses, against the
            # real deployed database instead of local dev. A one-time data
            # migration, not a repeatable ops procedure like mint-era/scaffold-
            # translation — generated the same way regardless, per this
            # project's own standing rule against hand-run ops steps.
            migrate-console-settings:
            #{migrate_console_settings_recipe}

            # `make rename-schema OLD=<old> NEW=<new>` — a native `ALTER SCHEMA
            # ... RENAME TO ...` over the same bastion tunnel mint-era uses,
            # for when this domain's own declared identity changes
            # (`formerly_known_as`) and its storage schema should follow. Purely
            # a Postgres namespace rename: every table/row/sequence inside it is
            # untouched, so this is safe to run against a live, in-use database
            # — the only requirement is that nothing else names the schema by
            # its OLD name at the moment this runs (this domain's own deployed
            # Lambda's HECKS_SCHEMA env var, most directly — run `make deploy`
            # right before or right after this, not with a long gap either way).
            rename-schema:
            #{rename_schema_recipe}

            #{pg_version ? <<~PGNATIVE : ""}
            # #{web_logical_id}'s own `pg` gem needs a native extension SAM's
            # default Ruby builder can't produce correctly: the precompiled
            # aarch64-linux binary needs GLIBC 2.29+, but Lambda's ruby3.2
            # MANAGED runtime is Amazon Linux 2 (glibc 2.26) — a real, live
            # "Init<NameError>: uninitialized constant PG::Error" caught this
            # (rescuing PG::Error itself failed to resolve, because pg's own
            # `require` died before ever reaching the file that defines it).
            # Built once, from source, in the SAME container `sam build
            # --use-container` itself uses (its glibc, not the host's, is what
            # has to match the deployed runtime) — then cached under
            # PG_NATIVE_DIR so every later `make deploy` skips straight to the
            # fast path. Delete that directory to force a clean rebuild.
            #
            # OpenSSL is built `no-shared` and linked STATICALLY into libpq, so
            # the libpq.so this produces carries no runtime dependency on
            # whatever OpenSSL (if any) happens to already be on the Lambda
            # execution image — sidesteps the AL2 package conflict between
            # `openssl-libs` and the build image's own pre-installed
            # `openssl-snapsafe-libs` entirely, rather than fighting it.
            PG_NATIVE_DIR := #{root}/tmp/pg-native-arm64-ruby3.2

            $(PG_NATIVE_DIR)/pg_ext.so:
            \t@mkdir -p $(PG_NATIVE_DIR)
            \t@echo "Building #{web_logical_id}'s pg native extension from source (cached under $(PG_NATIVE_DIR) after this — a few minutes, one time only)..."
            \tdocker run --rm --platform linux/arm64 -v $(PG_NATIVE_DIR):/out \\
            \t\t--entrypoint /bin/bash public.ecr.aws/sam/build-ruby3.2:latest-arm64 -c ' \\
            \t\t\tset -e; \\
            \t\t\tyum install -y perl-IPC-Cmd >/dev/null; \\
            \t\t\tcd /tmp; \\
            \t\t\tcurl -sL https://www.openssl.org/source/openssl-3.0.15.tar.gz | tar xz; \\
            \t\t\tcd openssl-3.0.15; \\
            \t\t\t./Configure linux-aarch64 no-shared no-tests --prefix=/tmp/openssl-install >/dev/null; \\
            \t\t\tmake -j$$(nproc) >/dev/null; \\
            \t\t\tmake install_sw >/dev/null; \\
            \t\t\tcd /tmp; \\
            \t\t\tcurl -sL https://ftp.postgresql.org/pub/source/v16.4/postgresql-16.4.tar.gz | tar xz; \\
            \t\t\tcd postgresql-16.4; \\
            \t\t\tCPPFLAGS="-I/tmp/openssl-install/include" LDFLAGS="-L/tmp/openssl-install/lib" \\
            \t\t\t\t./configure --without-readline --without-zlib --without-icu --with-ssl=openssl --prefix=/tmp/pg-install >/dev/null; \\
            \t\t\tmake -C src/include install >/dev/null; \\
            \t\t\tmake -C src/interfaces/libpq -j$$(nproc) install >/dev/null; \\
            \t\t\tcd /tmp; \\
            \t\t\tgem fetch pg -v #{pg_version} --platform ruby >/dev/null; \\
            \t\t\tgem unpack pg-#{pg_version}.gem --target=/tmp/gemsrc >/dev/null; \\
            \t\t\tcd /tmp/gemsrc/pg-#{pg_version}/ext; \\
            \t\t\truby -I.. -I../lib extconf.rb --with-pg-include=/tmp/pg-install/include --with-pg-lib=/tmp/pg-install/lib >/dev/null; \\
            \t\t\tmake >/dev/null; \\
            \t\t\tcp pg_ext.so /out/pg_ext.so; \\
            \t\t\tcp /tmp/pg-install/lib/libpq.so.5.16 /out/libpq.so.5.16; \\
            \t\t'

            # `find`, not a hardcoded gem-version path — survives #{domain}'s
            # own pg version bumping in its Gemfile.lock without this Makefile
            # needing regeneration to match. libpq.so.5.16 lands beside the
            # rest of #{web_logical_id}'s code at /var/task/lib — the ruby3.2
            # base image's OWN baked-in LD_LIBRARY_PATH default already searches
            # that exact path, so no rpath patching AND no explicit
            # LD_LIBRARY_PATH override belongs in template.yaml (setting one
            # there REPLACES the image's full default list instead of extending
            # it — a real, live "libcrypt.so.1: cannot open shared object file"
            # caught this — #{web_logical_id}'s own Environment no longer sets
            # it at all, on purpose).
            .PHONY: patch-pg-native
            patch-pg-native: $(PG_NATIVE_DIR)/pg_ext.so
            \t@PG_EXT=$$(find .aws-sam/build/#{web_logical_id}/vendor/bundle -path "*/pg-*/lib/3.2/pg_ext.so" | head -1); \\
            \t\ttest -n "$$PG_EXT" || { echo "patch-pg-native: no pg_ext.so found under .aws-sam/build/#{web_logical_id} — run sam build --use-container #{web_logical_id} first"; exit 1; }; \\
            \t\tcp $(PG_NATIVE_DIR)/pg_ext.so "$$PG_EXT"
            \t@mkdir -p .aws-sam/build/#{web_logical_id}/lib
            \tcp $(PG_NATIVE_DIR)/libpq.so.5.16 .aws-sam/build/#{web_logical_id}/lib/libpq.so.5.16
            \tln -sf libpq.so.5.16 .aws-sam/build/#{web_logical_id}/lib/libpq.so.5

            PGNATIVE
            #{google_oauth_present ? <<~SYNCOAUTH : ""}
            # Owns #{stack_name}-web-google-oauth's WHOLE lifecycle (create on
            # first run, update every run after — idempotent, cheap, no reason
            # to cache the way patch-pg-native's own multi-minute build does) —
            # deliberately OUTSIDE CloudFormation, straight from #{domain}'s own
            # gitignored .env.local, so the real client_id/secret never lands in
            # this generated, git-TRACKED template.yaml as plaintext. Read by
            # name (`{{resolve:secretsmanager:#{stack_name}-web-google-oauth:...}}`,
            # template.yaml's own Environment — #{rust_web ? logical_id : web_logical_id}'s
            # own), not by `!Ref` — see that comment for why this secret isn't a
            # stack resource at all. NOT nested inside patch-pg-native's own
            # pg_version gate above -- a real, live "No rule to make target
            # `sync-google-oauth'" caught that this target used to only exist
            # when a Ruby WebFunction (with its own pg gem) was also present,
            # even though Google OAuth itself has nothing to do with pg at all.
            .PHONY: sync-google-oauth
            sync-google-oauth:
            \t@CLIENT_ID=$$(grep '^GOOGLE_CLIENT_ID=' #{domain}/.env.local | cut -d= -f2-); \\
            \t\tCLIENT_SECRET=$$(grep '^GOOGLE_CLIENT_SECRET=' #{domain}/.env.local | cut -d= -f2-); \\
            \t\ttest -n "$$CLIENT_ID" -a -n "$$CLIENT_SECRET" || { echo "sync-google-oauth: #{domain}/.env.local is missing GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET"; exit 1; }; \\
            \t\tSECRET_JSON=$$(ruby -rjson -e 'puts JSON.generate({client_id: ARGV[0], client_secret: ARGV[1]})' "$$CLIENT_ID" "$$CLIENT_SECRET"); \\
            \t\taws secretsmanager put-secret-value --secret-id #{stack_name}-web-google-oauth --secret-string "$$SECRET_JSON" >/dev/null 2>&1 || \\
            \t\taws secretsmanager create-secret --name #{stack_name}-web-google-oauth --secret-string "$$SECRET_JSON" >/dev/null

            SYNCOAUTH
            # `make deploy` — THE one command. Chains `sam build`, `sam deploy`
            # (creates/updates the VPC+RDS+Lambda stack), then `mint-era` (safe
            # to run every time — a second boot against an already-held era 1
            # is a no-op, era_resolver.rb's own quiet-reboot branch) so a fresh
            # database always ends this command with era 1 actually held, not a
            # separate step someone has to remember. No hand-run AWS CLI
            # sequence anywhere in this path.
            #{google_oauth_present ? <<~OAUTHNOTE : ""}
            # deploy's own last step below looks up #{web_logical_id}'s
            # CURRENTLY deployed Function URL live (not tracked anywhere
            # generated) and passes it as WebRedirectBaseUrl -- see that
            # Parameter's own comment, above, for why GOOGLE_REDIRECT_URI can't
            # just be a CloudFormation intrinsic. Empty on a genuine first
            # deploy (before the Url exists at all); every deploy after that
            # finds the real, STABLE hostname (confirmed unchanged across every
            # redeploy this session) and self-heals GOOGLE_REDIRECT_URI to match.
            OAUTHNOTE
            #{shared ? <<~SHAREDNOTE : ""}
            # deploy's own last step below looks up #{owner_domain_name}'s live
            # stack Outputs (never tracked anywhere generated -- same reasoning
            # as WebRedirectBaseUrl's own live lookup above, and the SAME
            # `aws cloudformation describe-stacks` pattern mint-era's own eval
            # chain, below, already proves works against a sibling stack) and
            # passes them as this template's own Owning* Parameters.
            SHAREDNOTE
            .PHONY: deploy mint-era
            deploy:
            #{if dispatch_none
                "\t# ONE build only -- dispatch \"None\" means there is no\n\t# #{logical_id} of any kind (no cargo-lambda, no rust artifact, no\n\t# verify-parity: nothing rust/host-shaped for this domain at all),\n\t# so unlike every other WebFunction-carrying domain there is no\n\t# second build to protect from `sam build <resource>`'s own\n\t# WIPES-.aws-sam/build/-first behavior (build-#{logical_id}'s own\n\t# sibling comment on why that matters for domains that DO have one)\n\t# and nothing to restore afterward.\n\tsam build --use-container #{web_logical_id}\n\t$(MAKE) patch-pg-native"
              elsif pg_version
                "\t# TWO SEPARATE builds, not one `--use-container` run -- that flag is\n\t# global to `sam build`, but #{logical_id} deliberately builds on\n\t# THIS machine's own toolchain (cargo-lambda already cross-compiles\n\t# to arm64 without a container -- build-#{logical_id}'s own comment\n\t# on why), which a generic provided.al2023 container doesn't have\n\t# at all (a real, live \"Make Failed\" caught this). Only #{web_logical_id}\n\t# needs the container, to cross-compile pg's native extension for\n\t# Amazon Linux -- `sam build <resource>` WIPES .aws-sam/build/ before\n\t# building just the one named, so #{logical_id}'s own build gets\n\t# restored below (restore-#{logical_id}-build's own comment on why).\n\tsam build #{logical_id}\n\tsam build --use-container #{web_logical_id}\n\t$(MAKE) restore-#{logical_id}-build\n\t$(MAKE) patch-pg-native\n\t$(MAKE) verify-parity-#{logical_id}"
              elsif web_handler_present
                "\t# TWO SEPARATE builds -- #{web_logical_id} has no native extension to\n\t# cross-compile (no `pg` in #{domain}/Gemfile.lock), so a plain `sam\n\t# build` targets it fine; #{logical_id} still gets its own `sam build\n\t# <resource>` first, then restored below -- `sam build <resource>`\n\t# WIPES .aws-sam/build/ before building just the one named, so the\n\t# second call here would otherwise erase #{logical_id}'s own build\n\t# (restore-#{logical_id}-build's own comment on why).\n\tsam build #{logical_id}\n\tsam build #{web_logical_id}\n\t$(MAKE) restore-#{logical_id}-build\n\t$(MAKE) verify-parity-#{logical_id}"
              else
                "\tsam build\n\t$(MAKE) verify-parity-#{logical_id}"
              end}
            #{shared ? "" : <<~PREDEPLOYBRIDGE.each_line.map { |l| "\t" + l }.join.rstrip
                # THE TRANSACTION-SAFETY GAP, closed for the case that actually
                # matters: `sam deploy` below is what flips this Lambda's own
                # HECKS_DOMAIN/HECKS_SCHEMA env vars live — the INSTANT it
                # completes, real traffic can hit a domain/schema combination
                # whose era history hasn't been bridged yet if THIS domain was
                # just renamed (formerly_known_as) or its schema just moved.
                # `mint-era` already bridges that (era_resolver.rb's own
                # rename_domain! path, idempotent either way) — it only ran
                # AFTER `sam deploy` before this existed, which is exactly the
                # order that left a real live window open the one time this was
                # actually run in anger (an SSM tunnel flaked mid-bridge, after
                # the Lambda had already flipped over).
                #
                # STILL RUNS AFTER TOO (unchanged, below) — this pre-check
                # cannot replace that: a domain's VERY FIRST deploy has no
                # stack, hence no RDS, hence nothing to tunnel to yet, so
                # mint-era's real first run has to stay where it always was,
                # once `sam deploy` has just created that RDS instance. This
                # only ADDS a second, EARLIER run for a domain that already has
                # a live stack (a rename or an ordinary redeploy) — cheap and
                # safe either way, since mint-era's own quiet-reboot path is a
                # no-op the moment nothing has actually changed.
                #
                # See predeploy_bridge_shell's own comment (bin/project_deploy,
                # above, right before deploy_recipe_lines) for why this branches
                # on google_oauth_present at all -- the short version: adding
                # Google OAuth to an EXISTING stack would otherwise deadlock this
                # exact pre-check against outputs the upcoming sam deploy (not
                # yet run) hasn't created.
                #{predeploy_bridge_shell}
                PREDEPLOYBRIDGE
            }
            #{deploy_recipe_lines}
            \t$(MAKE) mint-era
          MAKE

          # Everything `sam deploy --guided` asks interactively — stack name,
          # region, capabilities, rollback behavior — is already known once the
          # domain and its deployed_to("AwsLambda") block are: none of it needs
          # a human typing answers on every deploy. There's no secret to carry
          # here either now: DATABASE_URL is composed inside the template itself
          # from RDS's own auto-generated Secrets Manager password, so nothing
          # gets typed, saved, or passed as a --parameter-overrides flag at all.
          samconfig_toml = <<~TOML
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
            # this file rather than hand-editing.
            version = 0.1

            [default.deploy.parameters]
            stack_name = "#{stack_name}"
            region = "#{region}"
            resolve_s3 = true
            s3_prefix = "#{stack_name}"
            capabilities = "CAPABILITY_IAM"
            confirm_changeset = false
            disable_rollback = false
          TOML

          files = { "template.yaml" => template_yaml }
          files["bastion.yaml"] = bastion_yaml if bastion_yaml
          files["Makefile"] = makefile_content
          files["samconfig.toml"] = samconfig_toml
          files
        end

        # Builds the CloudFront/WAFv2/logging resources a `PII`-marked domain gets fronted by.
        #
        # **`PII` → CloudFront** — once a domain marks a field "pii", its own public
        # surface (`WebFunction` when one exists, `#{logical_id}` otherwise —
        # `fronted_logical_id`, computed where both are known, in `call`) gets
        # fronted by a distribution carrying a WAFv2 WebACL (AWS managed rule
        # groups), security response headers, geo-restriction, and access
        # logging — every other domain's own template is untouched
        # (`pii_detected` false means `call` never invokes this at all).
        #
        # **`OAC` only for the AWS_IAM case** (`use_oac`) — the already-public
        # `WebFunction`/`rust_web` shape (`AuthType: NONE`) is left exactly as
        # reachable as it already was; CloudFront adds WAF/headers/geo/logging
        # on top of that, it does not change who could already call the
        # Function URL directly. `#{logical_id}` itself (the AWS_IAM,
        # internal-dispatch default) is the opposite: OAC lets CloudFront sign
        # requests to it via SigV4 while `PiiLambdaInvokePermission`'s own
        # `SourceArn` admits only this one distribution — direct, unsigned
        # access to the Function URL stays refused exactly as it was before
        # this ran.
        #
        # **Managed cache/origin-request policy ids** — not custom resources.
        # `4135ea2d-6df8-44a3-9df3-4b5a84be39ad`/`216adef6-5c7f-47e4-b989-
        # 5492eafa07d3` are AWS's own permanent, account-independent
        # `Managed-CachingDisabled`/`Managed-AllViewer` ids (the same ones the
        # console's own dropdown offers) — this fronts a Lambda dispatch
        # endpoint, not a static site; caching a response meant for exactly
        # one caller would be a real correctness bug, not a performance choice
        # made once here.
        #
        # @param fronted_logical_id [String] the Lambda resource this distribution fronts
        # @param use_oac [Boolean] true only when `fronted_logical_id`'s own FunctionUrlConfig is
        #   AWS_IAM (never true for WebFunction/rust_web, both always `NONE`)
        # @param geo_restriction_type ["none", "allowlist", "blocklist"] `deployed_to`'s own
        #   `geo_restriction` setting; "none" (no restriction, structurally present so a later
        #   change is a one-line `deployed_to` edit, not a template rewrite) when unset
        # @param geo_restriction_countries [Array<String>] ISO 3166-1 alpha-2 codes; ignored when
        #   `geo_restriction_type` is "none"
        # @return [String] the Resources entries to splice in before Outputs:, absolutely
        #   indented to 2 spaces (this stack's own top-level Resources entry column)
        def pii_cloudfront_yaml(fronted_logical_id:, use_oac:, geo_restriction_type:, geo_restriction_countries:)
          reindent = ->(text) { text.each_line.map { |line| line.strip.empty? ? line : "  #{line}" }.join }

          # Not pre-reindented (unlike the return value as a whole, below) — each
          # is spliced back into the still-being-dedented RESOURCES heredoc via
          # `#{...}`, which the outer `reindent.call` already shifts by 2
          # spaces once; reindenting here too would double it.
          origin_access_control = use_oac ? <<~OAC : ""
            PiiOriginAccessControl:
              Type: AWS::CloudFront::OriginAccessControl
              Properties:
                OriginAccessControlConfig:
                  Name: !Sub "${AWS::StackName}-pii-oac"
                  OriginAccessControlOriginType: lambda
                  SigningBehavior: always
                  SigningProtocol: sigv4
          OAC

          invoke_permission = <<~PERMISSION
            PiiLambdaInvokePermission:
              Type: AWS::Lambda::Permission
              Properties:
                Action: lambda:InvokeFunctionUrl
                FunctionName: !Ref #{fronted_logical_id}
                Principal: cloudfront.amazonaws.com
                SourceArn: !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${PiiDistribution}"
                FunctionUrlAuthType: #{use_oac ? "AWS_IAM" : "NONE"}
          PERMISSION

          countries_yaml = geo_restriction_countries.map { |code| "              - #{code}" }.join("\n")

          reindent.call(<<~RESOURCES)
            PiiAccessLogsBucket:
              Type: AWS::S3::Bucket
              Properties:
                # `BucketOwnerPreferred`, not the newer `BucketOwnerEnforced`
                # default — CloudFront's own classic access-log delivery
                # (`Logging:`, on PiiDistribution below) still authorizes itself
                # via a canned ACL (`AccessControlTranslation` between accounts is
                # a distinct, newer mechanism this bucket has no other account to
                # need), which an ACLs-disabled bucket refuses outright.
                OwnershipControls:
                  Rules:
                    - ObjectOwnership: BucketOwnerPreferred
                AccessControl: LogDeliveryWrite
                LifecycleConfiguration:
                  Rules:
                    - Id: ExpirePiiAccessLogs
                      Status: Enabled
                      ExpirationInDays: 365

            PiiResponseHeadersPolicy:
              Type: AWS::CloudFront::ResponseHeadersPolicy
              Properties:
                ResponseHeadersPolicyConfig:
                  Name: !Sub "${AWS::StackName}-pii-headers"
                  SecurityHeadersConfig:
                    StrictTransportSecurity:
                      AccessControlMaxAgeSec: 63072000
                      IncludeSubdomains: true
                      Override: true
                    ContentTypeOptions:
                      Override: true
                    FrameOptions:
                      FrameOption: DENY
                      Override: true
                    ReferrerPolicy:
                      ReferrerPolicy: same-origin
                      Override: true
                    XSSProtection:
                      ModeBlock: true
                      Protection: true
                      Override: true

            PiiWebAcl:
              Type: AWS::WAFv2::WebACL
              Properties:
                Name: !Sub "${AWS::StackName}-pii-waf"
                Scope: CLOUDFRONT
                DefaultAction:
                  Allow: {}
                VisibilityConfig:
                  SampledRequestsEnabled: true
                  CloudWatchMetricsEnabled: true
                  MetricName: !Sub "${AWS::StackName}PiiWebAcl"
                Rules:
                  - Name: AWSManagedRulesCommonRuleSet
                    Priority: 0
                    OverrideAction:
                      None: {}
                    Statement:
                      ManagedRuleGroupStatement:
                        VendorName: AWS
                        Name: AWSManagedRulesCommonRuleSet
                    VisibilityConfig:
                      SampledRequestsEnabled: true
                      CloudWatchMetricsEnabled: true
                      MetricName: !Sub "${AWS::StackName}PiiCommonRuleSet"
                  - Name: AWSManagedRulesKnownBadInputsRuleSet
                    Priority: 1
                    OverrideAction:
                      None: {}
                    Statement:
                      ManagedRuleGroupStatement:
                        VendorName: AWS
                        Name: AWSManagedRulesKnownBadInputsRuleSet
                    VisibilityConfig:
                      SampledRequestsEnabled: true
                      CloudWatchMetricsEnabled: true
                      MetricName: !Sub "${AWS::StackName}PiiKnownBadInputs"

            #{origin_access_control}
            PiiDistribution:
              Type: AWS::CloudFront::Distribution
              Properties:
                DistributionConfig:
                  Enabled: true
                  HttpVersion: http2
                  WebACLId: !GetAtt PiiWebAcl.Arn
                  Restrictions:
                    GeoRestriction:
                      RestrictionType: #{geo_restriction_type}
                      Locations:#{geo_restriction_type == "none" ? " []" : "\n" + countries_yaml}
                  Logging:
                    Bucket: !GetAtt PiiAccessLogsBucket.RegionalDomainName
                    IncludeCookies: false
                    Prefix: cloudfront/
                  Origins:
                    - Id: PiiOrigin
                      # `!Select [2, !Split ["/", ...]]` — the standard AWS-documented
                      # way to pull the bare hostname out of a Function URL's own
                      # `https://<id>.lambda-url.<region>.on.aws/` shape for use as a
                      # CustomOriginConfig DomainName, which admits no scheme or path.
                      DomainName: !Select [2, !Split ["/", !GetAtt #{fronted_logical_id}Url.FunctionUrl]]
                      CustomOriginConfig:
                        OriginProtocolPolicy: https-only
                        OriginSSLProtocols: [TLSv1.2]
            #{use_oac ? "          OriginAccessControlId: !Ref PiiOriginAccessControl" : ""}
                  DefaultCacheBehavior:
                    TargetOriginId: PiiOrigin
                    ViewerProtocolPolicy: redirect-to-https
                    AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
                    CachedMethods: [GET, HEAD]
                    CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
                    OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3
                    ResponseHeadersPolicyId: !Ref PiiResponseHeadersPolicy

            #{invoke_permission}
          RESOURCES
        end

      end
    end
  end
end
