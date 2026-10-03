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

        module_function

        # Generates `rds.yaml`, `box.yaml`, `Caddyfile`, `services.json`, `render-compose.sh`,
        # `fetch-secrets.sh`, `deploy-box.sh` and a `Makefile`.
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
            "render-compose.sh" => template("render-compose.sh.tmpl", "STACK" => plan.infra_name, "REGION" => region,
                                                                      "DB_NAME" => plan.database_name),
            "fetch-secrets.sh" => File.read(File.join(TEMPLATE_DIR, "fetch-secrets.sh")),
            "deploy-box.sh" => deploy_box_sh(plan, region),
            "Makefile" => makefile(plan)
          }
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
          arns = plan.secret_prefixes.map { |p| p.end_with?("*") ? p : "#{p}-*" }
          arns.push(plan.origin_secret.end_with?("*") ? plan.origin_secret : "#{plan.origin_secret}-*") if plan.origin_secret
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

        # One ECR repository per container, keeping the newest 30 images.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] CloudFormation resources, each preceded by a blank line
        def ecr_repositories(plan)
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
          "#{caddy_header(plan)}#{caddy_global(guarded)}\n:80 {\n#{site}}\n"
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
          return "{\n\tauto_https off\n\tadmin off\n}\n" unless guarded

          "{\n\tauto_https off\n\tadmin off\n\tservers {\n\t\ttrusted_proxies static 0.0.0.0/0 ::/0\n\t}\n}\n"
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
          services = plan.containers.to_h do |c|
            [c.name, { "name" => c.name, "repository" => c.repository, "port" => c.port,
                       "env" => c.env, "secrets" => c.secrets }]
          end
          origin = plan.origin_secret ? { "header" => plan.origin_header, "secret" => plan.origin_secret } : nil
          json = JSON.pretty_generate({ "services" => services, "origin" => origin })
          # An empty object prints as `{}` or `{` newline `}`, depending on the json gem.
          "#{json.gsub(/\{\s*\}/, '{}')}\n"
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [String] `deploy-box.sh`
        def deploy_box_sh(plan, region)
          template("deploy-box.sh.tmpl", "STACK" => plan.infra_name, "BOX_STACK" => plan.box_stack,
                                         "RDS_STACK" => plan.rds_stack, "REGION" => region,
                                         "DIR" => "/opt/#{plan.infra_name}", "HEALTH_CHECKS" => health_checks(plan))
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
          if plan.origin_header
            [
              "S=$(grep ^ORIGIN_SECRET= caddy.secrets.env | cut -d= -f2-)",
              probe.call("a request without the origin secret is refused", "", '[ "$code" = 403 ]'),
              probe.call("a request with the origin secret is served", %( -H "#{plan.origin_header}: $S"),
                         '[ "${code#5}" = "$code" ]')
            ].join("\n")
          else
            probe.call("the proxy serves /", "", '[ "${code#5}" = "$code" ]')
          end
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] a Makefile whose targets create the two stacks and roll the box
        def makefile(plan)
          <<~MAKE
            # #{plan.infra_name}: one app box and one RDS instance.
            #   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c
            #   make deploy [TAGS="web=20260101 worker=20260101"]
            RDS_STACK = #{plan.rds_stack}
            BOX_STACK = #{plan.box_stack}

            .PHONY: stacks deploy
            stacks:
            \taws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \\
            \t\t--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS)
            \taws cloudformation deploy --template-file box.yaml --stack-name $(BOX_STACK) --capabilities CAPABILITY_IAM \\
            \t\t--parameter-overrides VpcId=$(VPC) SubnetId=$(PUBLIC_SUBNET) \\
            \t\tDbSecurityGroupId=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecurityGroupId'].OutputValue" --output text) \\
            \t\tDbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text) \\
            \t\tAlertTopicArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text)

            deploy:
            \tbash ./deploy-box.sh $(TAGS)
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
