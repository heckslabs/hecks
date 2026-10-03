require "json"
require_relative "../../projector"
require_relative "box/settings"

module Hecks
  module Projections
    module Deploy
      # The AWS single-box deploy target for `deployed_to("AwsBox")`: one EC2 instance that runs the
      # domain's containers with Docker Compose behind Caddy, reading a plain RDS Postgres instance.
      # It renders two CloudFormation stacks (the database, the box), the proxy's `Caddyfile`, the
      # `services.json` compose is rendered from, and the scripts that roll the box.
      module Box
        extend Projector::Target

        projects_as :aws_box, needs_world: true, emits: :files

        TEMPLATE_DIR = File.join(__dir__, "box", "templates").freeze

        # Region suffixes of an Elastic address's public DNS name; us-east-1 is the only region with
        # the legacy `compute-1` form.
        LEGACY_COMPUTE_REGION = "us-east-1".freeze
        # Extra sites mounted beside the proxy's own, such as the loopback listener `deploy-box.sh`
        # adds for a rehearsal's smoke run. Nothing matches in production.
        CADDY_EXTRA = "import /etc/caddy/extra/*\n".freeze

        module_function

        # Generates `rds.yaml`, `box.yaml`, `Caddyfile`, `services.json`, `render-compose.sh`,
        # `fetch-secrets.sh`, `deploy-box.sh` and a `Makefile`, and for a world that declares a
        # `migration`, `restore-to-rds.sh`, `verify-copy.sh` and `MIGRATION.md`.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Fargate.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings are invalid or conflict
        def call(bluebook:, options: {})
          world, domain, world_file = options.values_at(:world, :domain_dir, :world_file)
          tenant = options[:tenant] || {}
          settings = tenant_settings(world.for_verb("deployed_to"), tenant, File.basename(domain))
          infra_name = (settings[:stack_name] || File.basename(domain)).to_s.tr("_", "-").downcase

          target = declare(world.domain, settings, world_file)
          plan = Settings.resolve(deploy_settings: settings, target: target, infra_name: infra_name)
          render_all(plan, target.state[:region].value)
        end

        # Applies the `--tenant` suffix to the stack name, as `Fargate.call` does.
        #
        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @param tenant [Hash] the `--tenant` and `--schema` options
        # @param domain_name [String] the domain directory's name
        # @return [Hash{Symbol => Object}] the settings with the tenant's stack name
        def tenant_settings(settings, tenant, domain_name)
          return settings unless tenant[:tenant]

          settings.merge(stack_name: "#{settings[:stack_name] || domain_name}-#{tenant[:tenant]}")
        end

        # Validates the target through the Deploy bluebook's own `BoxTarget.Declare`.
        #
        # @param domain [String] the world's domain name
        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @param world_file [String] the `.world` file, named in a refusal
        # @return [Object] the declared target aggregate
        # @raise [ArgumentError] when the bluebook refuses a value
        def declare(domain, settings, world_file)
          dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          dispatcher.dispatch(
            "Deploy::BoxTarget.Declare",
            with: {
              domain: { value: domain }, region: { value: settings[:region] },
              instance_type: { value: settings.fetch(:instance_type, "t4g.medium") },
              volume_gb: { value: settings.fetch(:volume_gb, 30) },
              database_class: { value: settings.fetch(:database_class, "db.t4g.small") },
              storage_gb: { value: settings.fetch(:storage_gb, 20) }
            }
          ).instance
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          raise ArgumentError, "#{world_file}'s deployed_to(\"AwsBox\") is invalid: #{e.message}"
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [Hash{String => String}] every generated file
        def render_all(plan, region)
          {
            "rds.yaml" => rds_yaml(plan), "box.yaml" => box_yaml(plan, region),
            "Caddyfile" => caddyfile(plan), "services.json" => services_json(plan),
            "render-compose.sh" => render_compose_sh(plan, region),
            "fetch-secrets.sh" => File.read(File.join(TEMPLATE_DIR, "fetch-secrets.sh")),
            "deploy-box.sh" => deploy_box_sh(plan, region),
            "Makefile" => makefile(plan)
          }.merge(migration_files(plan))
        end

        # The tooling that moves a project's data from its old database into the RDS instance, for
        # a world that declares a `migration`.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [Hash{String => String}] `restore-to-rds.sh`, `verify-copy.sh` and `MIGRATION.md`,
        #   or nothing
        def migration_files(plan)
          migration = plan.migration
          return {} unless migration

          values = { "STACK" => plan.infra_name, "SCHEMAS" => migration.schemas.join(" "),
                     "SCHEMAS_CSV" => migration.schemas.join(","), "DATABASE" => migration.database,
                     "SOURCE_DATABASE" => migration.source_database }
          {
            "restore-to-rds.sh" => template("restore-to-rds.sh.tmpl", values),
            "verify-copy.sh"    => template("verify-copy.sh.tmpl", values),
            "MIGRATION.md"      => migration_md(plan)
          }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the runbook for moving onto the box, in the order the steps are run
        def migration_md(plan)
          migration = plan.migration
          deploy = plan.task_definition ? "make deploy TASKDEF=#{plan.task_definition}:<revision>" : "make deploy"
          <<~MD
            # Moving #{plan.infra_name} onto the box and RDS

            Generated from the world's `migration` setting. Nothing here has been run for you.

            Schemas to copy: #{migration.schemas.map { |name| "`#{name}`" }.join(', ')}, in database
            `#{migration.source_database}` on the old server and `#{migration.database}` on RDS.

            ## Before cutover

            1. Create the stacks: `make stacks VPC=... PRIVATE_SUBNETS=... PUBLIC_SUBNET=...`. To rehearse first,
               deploy `rds.yaml` and `box.yaml` under other stack names with `Rehearsal=true`: the database is then
               deleted with its stack and the box gets no stable public address. Delete the rehearsal stacks after.
            2. Copy the data. The bastion is any instance that can reach both databases.

               ```
               RDS_HOST=$(aws cloudformation describe-stacks --stack-name #{plan.rds_stack} --query "Stacks[0].Outputs[?OutputKey=='DbEndpoint'].OutputValue" --output text)
               RDS_SECRET=$(aws cloudformation describe-stacks --stack-name #{plan.rds_stack} --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text)
               bash restore-to-rds.sh <bastion-instance-id> <old-host> <old-secret-arn> "$RDS_HOST" "$RDS_SECRET"
               ```

               It copies each schema, refreshes the materialized views a plain `pg_restore` cannot, then runs
               `verify-copy.sh`, which compares structure and the exact row count of every table and prints `OK`
               only if both match. Re-run with `FORCE=1` to reload.
            3. Deploy the app onto the box: `#{deploy}`. The deploy ends with health checks on the box.
            4. Run the project's own smoke test against the box before any traffic moves.

            ## Cutover

            1. Stop writes on the old stack, then run `restore-to-rds.sh` again with `FORCE=1` for a final copy and
               wait for `OK`.
            2. Point the CDN's origin at the box stack's `AppOriginDomain` output.
            3. Keep the old database untouched for several days, and take a final snapshot before deleting it.

            ## Rollback

            Until the first write lands on RDS, point the origin back. After that, writes taken by both databases
            cannot be merged: choose one side and copy it over the other (swap the hosts and secrets, and set
            `SRC_DB` and `DST_DB`, with `FORCE=1`). Do not change the domain's era in the same window, so a rollback
            only has to move data.
          MD
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [String] the script that renders the Compose file, from `services.json` or from
        #   an ECS task definition when the world names one
        def render_compose_sh(plan, region)
          if plan.task_definition
            template("render-compose-taskdef.sh.tmpl", "STACK" => plan.infra_name, "FAMILY" => plan.task_definition,
                                                        "PROXY_IMAGE" => plan.proxy_image)
          else
            template("render-compose.sh.tmpl", "STACK" => plan.infra_name, "REGION" => region,
                                               "DB_NAME" => plan.database_name, "PROXY_IMAGE" => plan.proxy_image)
          end
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the database stack
        def rds_yaml(plan)
          template("rds.yaml.tmpl", "STACK" => plan.infra_name, "DB_CLASS" => plan.database_class,
                                    "STORAGE_GB" => plan.storage_gb.to_s, "DB_NAME" => plan.database_name,
                                    "ENGINE_VERSION" => plan.engine_version, "BACKUP_DAYS" => plan.backup_days.to_s)
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [String] the box stack
        def box_yaml(plan, region)
          template("box.yaml.tmpl",
                   "STACK" => plan.infra_name, "INSTANCE_TYPE" => plan.instance_type,
                   "VOLUME_GB" => plan.volume_gb.to_s, "SNAPSHOTS_KEEP" => plan.snapshots_keep.to_s,
                   "AMI_PARAMETER" => ami_parameter(plan.instance_type),
                   "COMPUTE_DOMAIN" => compute_domain(region),
                   "SECRET_RESOURCES" => secret_resources(plan), "TUNNEL_EGRESS" => tunnel_egress(plan),
                   "SWAP_COMMANDS" => swap_commands(plan), "ECR_REPOSITORIES" => ecr_repositories(plan),
                   "ECR_OUTPUTS" => ecr_outputs(plan))
        end

        # Graviton families end their generation digit with `g` (`t4g`, `m7gd`, `c6gn`).
        #
        # @param instance_type [String] an EC2 instance type
        # @return [String] the SSM parameter of the matching Amazon Linux image
        def ami_parameter(instance_type)
          arch = instance_type.split(".").first.match?(/\d+g[a-z]*\z/) ? "arm64" : "x86_64"
          "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-#{arch}"
        end

        # @param region [String] the AWS region
        # @return [String] the DNS suffix an Elastic address's public name ends with
        def compute_domain(region)
          region == LEGACY_COMPUTE_REGION ? "compute-1.amazonaws.com" : "#{region}.compute.amazonaws.com"
        end

        # One Secrets Manager statement resource per prefix. A name without a trailing `*` gets `-*`
        # for the random suffix AWS appends to every secret ARN.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] YAML list items, one per prefix, ending in a newline
        def secret_resources(plan)
          named = [plan.origin_secret, plan.tunnel_service&.token_secret].compact
          arns = (plan.secret_prefixes + named).map { |name| name.end_with?("*") ? name : "#{name}-*" }
          arns.uniq.map do |pattern|
            "                  - !Sub \"arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:#{pattern}\"\n"
          end.join.chomp
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the outbound rules a Cloudflare Tunnel sidecar needs, or nothing
        def tunnel_egress(plan)
          return "" unless plan.tunnel

          <<~YAML
            #{' ' * 8}# cloudflared dials out to the tunnel edge on 7844. Outbound only: nothing opens inbound.
            #{' ' * 8}- IpProtocol: tcp
            #{' ' * 8}  FromPort: 7844
            #{' ' * 8}  ToPort: 7844
            #{' ' * 8}  CidrIp: 0.0.0.0/0
            #{' ' * 8}  Description: tunnel to the edge
            #{' ' * 8}- IpProtocol: udp
            #{' ' * 8}  FromPort: 7844
            #{' ' * 8}  ToPort: 7844
            #{' ' * 8}  CidrIp: 0.0.0.0/0
            #{' ' * 8}  Description: tunnel to the edge (QUIC)
          YAML
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the user-data lines that add swap, or nothing when `swap_gb` is 0
        def swap_commands(plan)
          return "" if plan.swap_gb.zero?

          pad = " " * 10
          <<~SH.lines.map { |line| "#{pad}#{line}" }.join
            # swap so a memory spike at boot cannot take the box down
            fallocate -l #{plan.swap_gb}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
          SH
        end

        # One ECR repository per container, keeping the newest 30 images. A task definition names
        # images that already have repositories, so none are made.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] CloudFormation resources, each preceded by a blank line
        def ecr_repositories(plan)
          return "" if plan.task_definition

          plan.containers.map do |container|
            id = "#{logical(container.name)}Repository"
            <<~YAML.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join

              #{id}:
                Type: AWS::ECR::Repository
                Properties:
                  RepositoryName: #{container.repository}
                  ImageScanningConfiguration:
                    ScanOnPush: true
                  LifecyclePolicy:
                    LifecyclePolicyText: '{"rules":[{"rulePriority":1,"description":"keep the newest 30","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":30},"action":{"type":"expire"}}]}'
            YAML
          end.join.chomp
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] one repository URI output per container
        def ecr_outputs(plan)
          return "" if plan.task_definition

          plan.containers.map do |container|
            "  #{logical(container.name)}RepositoryUri:\n    Value: !GetAtt #{logical(container.name)}Repository.RepositoryUri\n"
          end.join.chomp
        end

        # @param name [String] a container name such as `web-app`
        # @return [String] a CloudFormation logical id fragment, such as `WebApp`
        def logical(name)
          name.split("-").map(&:capitalize).join
        end

        # The proxy's configuration: an optional origin-secret guard, one block per route and a
        # default for everything else.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the Caddyfile
        def caddyfile(plan)
          guarded = !plan.origin_header.nil?
          site =
            if guarded
              "\t@origin header #{plan.origin_header} {$ORIGIN_SECRET}\n\n\thandle @origin {\n" \
                "#{indent(indent(route_blocks(plan)))}\t}\n\n\thandle {\n\t\trespond \"Forbidden\" 403\n\t}\n"
            else
              indent(route_blocks(plan))
            end
          "#{caddy_header(plan)}#{caddy_global(guarded)}\n:80 {\n#{site}}\n\n#{CADDY_EXTRA}"
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the `handle` blocks for each route, then the default
        def route_blocks(plan)
          routes = plan.routes.each_with_index.map do |route, i|
            port = plan.containers.find { |c| c.name == route.container }.port
            "@r#{i + 1} path #{route.paths.join(' ')}\nhandle @r#{i + 1} {\n\treverse_proxy 127.0.0.1:#{port}\n}\n\n"
          end
          "#{routes.join}handle {\n\treverse_proxy 127.0.0.1:#{plan.default.port}\n}\n"
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the comment that opens the Caddyfile
        def caddy_header(plan)
          origin =
            if plan.origin_header
              "Only requests that carry #{plan.origin_header} with the origin secret are proxied;\n" \
                "# everything else gets a flat 403.\n"
            else
              "Every request is proxied.\n"
            end
          "# #{plan.infra_name}'s proxy. #{origin}"
        end

        # With a guard, the proxy trusts every source: a request that reaches a `handle` block has
        # already proved it came through the CDN by presenting the secret, and everything else is
        # refused. Caddy then keeps the client address the CDN put in X-Forwarded-For.
        #
        # @param guarded [Boolean] whether an origin secret guards the site
        # @return [String] the global options block
        def caddy_global(guarded)
          return "{\n\tauto_https disable_redirects\n\tadmin off\n}\n" unless guarded

          "{\n\tauto_https disable_redirects\n\tadmin off\n\tservers {\n\t\ttrusted_proxies static 0.0.0.0/0 ::/0\n\t}\n}\n"
        end

        # @param text [String] lines to indent one level with a tab
        # @return [String] the text, each non-blank line prefixed with a tab
        def indent(text)
          text.lines.map { |line| line.strip.empty? ? line : "\t#{line}" }.join
        end

        # The compose source: one entry per container, plus the origin secret the proxy checks.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] `services.json`
        def services_json(plan)
          services = plan.containers.to_h { |c| [c.name, service_entry(plan, c)] }
          origin = plan.origin_secret ? { "header" => plan.origin_header, "secret" => plan.origin_secret } : nil
          document = { "services" => services, "origin" => origin }
          document["task_definition"] = plan.task_definition if plan.task_definition
          document["tunnel"] = tunnel_entry(plan.tunnel_service) if plan.tunnel_service
          json = JSON.pretty_generate(document)
          # An empty object prints as `{}` or `{` newline `}`, depending on the json gem.
          "#{json.gsub(/\{\s*\}/, '{}')}\n"
        end

        # A container's entry. With a task definition the image, environment and secrets are read
        # from it at deploy time, so only the name and port are written here.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @param container [Settings::Container] the container
        # @return [Hash{String => Object}] its entry in `services.json`
        def service_entry(plan, container)
          entry = { "name" => container.name, "port" => container.port }
          return entry if plan.task_definition

          { "name" => container.name, "repository" => container.repository, "port" => container.port,
            "env" => container.env, "secrets" => container.secrets }
        end

        # @param tunnel [Settings::Tunnel] the declared tunnel service
        # @return [Hash{String => Object}] its entry in `services.json`
        def tunnel_entry(tunnel)
          { "url" => "http://127.0.0.1:#{tunnel.port}", "token_secret" => tunnel.token_secret, "image" => tunnel.image }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [String] `deploy-box.sh`
        def deploy_box_sh(plan, region)
          template("deploy-box.sh.tmpl", "STACK" => plan.infra_name, "BOX_STACK" => plan.box_stack,
                                         "RDS_STACK" => plan.rds_stack, "REGION" => region,
                                         "DIR" => "/opt/#{plan.infra_name}", "HEALTH_CHECKS" => health_checks(plan),
                                         "SMOKE_HEADER" => smoke_header(plan), "USAGE" => deploy_usage(plan))
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the line that makes the smoke listener present the origin secret, or nothing
        #   when the world has no origin guard
        def smoke_header(plan)
          plan.origin_header ? "\t\theader_up #{plan.origin_header} {$ORIGIN_SECRET}" : ""
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the comment lines that say how to call `deploy-box.sh`
        def deploy_usage(plan)
          if plan.task_definition
            <<~USAGE
              #   deploy-box.sh [task-definition]
              #
              # The task definition (a family or family:revision) defaults to the latest active revision of
              # #{plan.task_definition}. Secret values are resolved on the box by fetch-secrets.sh and never
              # pass through the SSM command.
            USAGE
          else
            <<~USAGE
              #   deploy-box.sh [name=tag ...]
              #
              # A container named without a tag runs its "latest" image. Secret values are resolved on the box by
              # fetch-secrets.sh and never pass through the SSM command.
            USAGE
          end
        end

        # The probes the post-roll check runs on the box, against the proxy on localhost.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] bash lines that set `BAD=1` on a failed probe
        def health_checks(plan)
          write_out = '-w "%{http_code}"' # rubocop:disable Style/FormatStringToken -- curl's own token
          probe = lambda do |label, args, wanted|
            <<~SH.chomp
              code=$(curl -s -o /dev/null #{write_out} --max-time 40 localhost/#{args})
              #{wanted} && echo "ok   #{label} -> $code" || { echo "FAIL #{label} -> $code"; BAD=1; }
            SH
          end
          probes =
            if plan.origin_header
              [
                "S=$(grep ^ORIGIN_SECRET= caddy.secrets.env | cut -d= -f2-)",
                probe.call("a request without the origin secret is refused", "", '[ "$code" = 403 ]'),
                probe.call("a request with the origin secret is served", %( -H "#{plan.origin_header}: $S"),
                           '[ "${code#5}" = "$code" ]')
              ]
            else
              [probe.call("the proxy serves /", "", '[ "${code#5}" = "$code" ]')]
            end
          (probes + tunnel_probe(plan)).join("\n")
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [Array<String>] the probe that waits for the tunnel to register, when one runs
        def tunnel_probe(plan)
          return [] unless plan.tunnel_service

          [<<~SH.chomp]
            for _ in 1 2 3 4 5 6; do
              n=$(docker compose -f compose.json logs --no-color cloudflared 2>&1 | grep -ci "registered tunnel connection" || true)
              [ "$n" -gt 0 ] && break
              sleep 5
            done
            [ "$n" -gt 0 ] && echo "ok   the tunnel registered $n connections" || { echo "FAIL the tunnel has no connection"; BAD=1; }
          SH
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] a Makefile whose targets create the two stacks and roll the box
        def makefile(plan)
          <<~MAKE
            # #{plan.infra_name}: one app box and one RDS instance.
            #   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c [REHEARSAL=true] [MEDIA_BUCKET=name]
            #   make deploy #{plan.task_definition ? '[TASKDEF=family:revision]' : '[TAGS="web=20260101 worker=20260101"]'}
            RDS_STACK = #{plan.rds_stack}
            BOX_STACK = #{plan.box_stack}
            REHEARSAL ?= false
            MEDIA_BUCKET ?=

            .PHONY: stacks deploy
            stacks:
            \taws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \\
            \t\t--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL)
            \taws cloudformation deploy --template-file box.yaml --stack-name $(BOX_STACK) --capabilities CAPABILITY_IAM \\
            \t\t--parameter-overrides VpcId=$(VPC) SubnetId=$(PUBLIC_SUBNET) Rehearsal=$(REHEARSAL) MediaBucket=$(MEDIA_BUCKET) \\
            \t\tDbSecurityGroupId=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecurityGroupId'].OutputValue" --output text) \\
            \t\tDbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text) \\
            \t\tAlertTopicArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text)

            deploy:
            \tbash ./deploy-box.sh $(#{plan.task_definition ? 'TASKDEF' : 'TAGS'})
          MAKE
        end

        # Fills `@@NAME@@` markers. A marker alone on its line is replaced together with the line,
        # so an empty value leaves no blank line behind; one inside a line is replaced in place.
        #
        # @param file [String] the template file's name in `TEMPLATE_DIR`
        # @param values [Hash{String => String}] marker name => text
        # @return [String] the rendered file
        def template(file, values)
          values.reduce(File.read(File.join(TEMPLATE_DIR, file))) do |text, (marker, value)|
            own_line = /^@@#{marker}@@\n/
            if text.match?(own_line)
              text.sub(own_line) { value.empty? || value.end_with?("\n") ? value : "#{value}\n" }
            else
              text.gsub("@@#{marker}@@") { value }
            end
          end
        end
      end
    end
  end
end
