require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/projections/deploy/template_diff"

# Two promises: no multi-container settings renders the single-container
# golden stack; setting them renders one task with several containers, routed by path.
RSpec.describe "hecks deploy project — a multi-container deployed_to(\"AwsFargate\") stack", :io do
  FARGATE_STACK_ROOT_DIR = File.expand_path("..", __dir__)
  FARGATE_STACK_GOLDEN_DIR = File.join(__dir__, "fixtures", "deploy_fargate_golden")
  FARGATE_STACK_FIXTURE_NAME = "scratch_fixture".freeze
  # Each world is generated once and shared by the examples that read it.
  module FargateStackGeneratedWorlds
    def self.fetch(key) = (@worlds ||= {})[key] ||= yield
  end

  FARGATE_STACK_BLUEBOOK = <<~FARGATE_STACK_BLUEBOOK.freeze
    Hecks.bluebook "Scratch" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
          invariant("named") { !value.to_s.empty? }
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  FARGATE_STACK_BLUEBOOK

  FARGATE_STACK_SINGLE_WORLDS = {
    "default"      => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          cpu 256
          memory 512
          port 8080
        end
      end
    WORLD
    "aurora_oauth" => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "eu-west-1"
          cpu 512
          memory 1024
          port 9000
          web "Rust"
          database "Aurora"
          stack_prefix "acme"
          stack_name "widget-shop"
          desired_count 2
          schema "widgets"
        end
      end
    WORLD
    "shared"       => <<~WORLD
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          database "Shared"
          owner "Harbor"
        end
      end
    WORLD
  }.freeze

  FARGATE_STACK_MULTI_WORLD = <<~'WORLD'.freeze
    Hecks.world "Scratch" do
      deployed_to("AwsFargate") do
        region "us-east-1"
        cpu 1024
        memory 3072
        port 8082
        database "Shared"
        owner "Harbor"
        stack_prefix "acme"
        stack_name "platform"
        desired_count 0
        desired_count_parameter "DesiredCount"
        execute_command true
        health_check_grace_period 10
        deregistration_delay 30
        db_name_parameter "OwningDatabaseName"
        install_dir "/app"
        build_context_dir "domain-build/"
        logical_ids service: "Service", cluster: "Cluster", alb: "Alb", listener: "Listener", target_group: "DomainTargetGroup",
                    ecr_repository: "DomainRepository", session_secret: "SessionSecret", distribution: "SiteDistribution",
                    execution_role: "ExecutionRole", task_role: "TaskRole", log_group: "LogGroup", task_definition: "TaskDefinition",
                    alb_security_group: "AlbSecurityGroup", ingress_from_alb: "ComputeIngressFromAlb"
        names family: "acme-platform", alb: "acme-platform-alb", alb_security_group_description: "acme platform ALB, HTTP from the CDN only",
              db_secret_policy: "SharedDatabaseSecretRead"
        execution_role_database_grant false
        domain_container name: "domain", repository: "acme-platform-domain", image_tag_parameter: "DomainImageTag", essential: true
        containers [
          { name: "website", repository: "acme-platform-website", port: 8080,
            env: { "HOST" => "0.0.0.0", "PORT" => "8080", "CDN_ORIGIN_SECRET" => "!Ref CdnOriginSecret" },
            secrets: { "AUTH_SECRET" => "!Ref SessionSecret" } },
          { name: "cms", repository: "acme-platform-cms", port: 8081, health_path: "/cms/api/access",
            env: { "NODE_ENV" => "production", "SITE_URL" => "!Ref SiteOrigin" } }
        ]
        default_container "website"
        routes [
          { container: "cms", paths: ["/cms/*"], priority: 10 },
          { container: "domain", paths: ["/registrations", "/registrations/*", "/webhooks/*"], priority: 20 },
          { container: "domain", paths: ["/login", "/logout", "/auth/*"], priority: 21 }
        ]
        domain_env "HECKS_ERA" => nil, "HECKS_WEB" => nil, "HECKS_SESSION_COOKIE" => "acme_session", "SITE_URL" => "!Ref SiteOrigin",
                   "BIND" => "0.0.0.0"
        parameters "SiteOrigin" => { type: "String", default: "https://www.example.com", description: "Public origin of the site." }
        cdn aliases: ["www.example.com", "example.com"],
            certificate_arn: "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000",
            retain: true, origin_ssl_protocols: ["TLSv1.2"], explicit_origin_ports: false,
            origin_secret: { header: "X-Origin-Secret", parameter: "CdnOriginSecret" },
            extra_origins: [{ id: "AssetsOrigin", domain_name: "!Sub \"assets-${AWS::AccountId}.s3.${AWS::Region}.amazonaws.com\"",
                              origin_access_control_id: "!ImportValue \"assets-OacId\"" }],
            default_behavior: { methods: "read", cache_policy: "e0fe29ef-0768-4698-8260-aa7c8d3abae0" },
            behaviors: [
              { path: "/_static/*", cache_policy: "caching_optimized", origin_request_policy: "all_viewer_except_host", compress: true },
              { path: "/api/*", methods: "all", viewer_protocol: "https-only" },
              { path: "/videos/*", origin: "AssetsOrigin", cache_policy: "caching_optimized", methods: "get_head", compress: false }
            ]
        buckets [{ id: "MediaBucket", name_prefix: "acme-platform-media", public_read: true, cors_origins: ["*"] }]
        generated_secrets [{ id: "CmsSecret", name: "acme-platform/cms-secret", description: "Signing secret for the CMS.", key: "secret" }]
        session_secret name: "acme-platform/session-secret", description: "Session signing secret."
        task_policies [
          { name: "MediaAccess", statements: [{ actions: ["s3:GetObject", "s3:PutObject"], resources: ["!Sub \"${MediaBucket.Arn}/*\""] }] }
        ]
        execution_policies [
          { name: "SessionSecretInject", statements: [{ actions: ["secretsmanager:GetSecretValue"], resources: ["!Ref SessionSecret"] }] }
        ]
        alerts topic: "acme-platform-alerts", email: "ops@example.com",
               alarms: [{ kind: "alb_5xx", description: "Targets are returning 5xx responses." }, "target_unhealthy", "cloudfront_5xx"],
               warmer: { paths: ["/", "/about.html"], namespace: "Acme/Synthetic", schedule_description: "Runs the site check." }
        outputs "MediaBucketName" => "!Ref MediaBucket"
      end
    end
  WORLD

  FARGATE_STACK_CLASH_WORLD = <<~WORLD.freeze
    Hecks.world "Scratch" do
      deployed_to("AwsFargate") do
        region "us-east-1"
        logical_ids alb: "Cluster", cluster: "Cluster"
      end
    end
  WORLD

  FARGATE_STACK_IMAGES = [{ "Fn::Sub" => "${DomainRepository.RepositoryUri}:${DomainImageTag}" },
                          { "Fn::Sub" => "${WebsiteRepository.RepositoryUri}:${WebsiteImageTag}" },
                          { "Fn::Sub" => "${CmsRepository.RepositoryUri}:${CmsImageTag}" }].freeze
  FARGATE_STACK_DRAIN = [[{ "Key" => "deregistration_delay.timeout_seconds", "Value" => "30" }]].freeze
  FARGATE_STACK_ROUTE_PATHS = [["/cms/*"], ["/registrations", "/registrations/*", "/webhooks/*"],
                               ["/login", "/logout", "/auth/*"]].freeze
  FARGATE_STACK_RULE_TARGETS = %w[CmsTargetGroup DomainTargetGroup DomainTargetGroup].freeze
  FARGATE_STACK_SERVICE_TUNING = { "EnableExecuteCommand" => true, "HealthCheckGracePeriodSeconds" => 10,
                                   "DesiredCount" => { "Ref" => "DesiredCount" } }.freeze
  FARGATE_STACK_ORIGIN_HEADERS = [{ "HeaderName" => "X-Origin-Secret", "HeaderValue" => { "Ref" => "CdnOriginSecret" } }].freeze
  FARGATE_STACK_ORIGIN_CONFIG = { "OriginProtocolPolicy" => "http-only", "OriginSSLProtocols" => ["TLSv1.2"] }.freeze
  FARGATE_STACK_ALARMS = %w[AlbTarget5xxAlarm DomainTargetUnhealthyAlarm WebsiteTargetUnhealthyAlarm
                            CmsTargetUnhealthyAlarm CloudFront5xxAlarm SyntheticCheckFailuresAlarm].freeze
  FARGATE_STACK_WARMER_RESOURCES = %w[CloudFrontMonitoringSubscription WarmerFunction WarmerSchedule WarmerRole
                                      SchedulerInvokeRole].freeze

  # The scratch domain under `dir`: its bluebook, the world, and the `.env.local` when one is given.
  def write_scratch_domain(dir, world_body, env_local)
    domain = File.join(dir, FARGATE_STACK_FIXTURE_NAME)
    bluebook_dir = File.join(domain, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "#{FARGATE_STACK_FIXTURE_NAME}.bluebook"), FARGATE_STACK_BLUEBOOK)
    File.write(File.join(bluebook_dir, "#{FARGATE_STACK_FIXTURE_NAME}.world"), world_body)
    File.write(File.join(domain, ".env.local"), env_local) if env_local
    domain
  end

  # The generated files of `out`, with the scratch paths replaced by placeholders.
  def read_generated(out, domain)
    Dir.children(out).to_h do |name|
      [name, File.read(File.join(out, name)).gsub(domain, "<domain>").gsub(FARGATE_STACK_ROOT_DIR, "<root>")]
    end
  end

  def generate(world_body, env_local: nil)
    Dir.mktmpdir do |dir|
      domain = write_scratch_domain(dir, world_body, env_local)
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: FARGATE_STACK_ROOT_DIR)
      return [nil, stderr] unless status.success?

      [read_generated(out, domain), stderr]
    end
  end

  def cached(key, world_body, **options)
    FargateStackGeneratedWorlds.fetch(key) { generate(world_body, **options) }
  end

  # The single-container world `name`, generated with a Google client id for the OAuth one.
  def single_world(name)
    env_local = name == "aurora_oauth" ? "GOOGLE_CLIENT_ID=abc\n" : nil
    cached(name, FARGATE_STACK_SINGLE_WORLDS.fetch(name), env_local: env_local)
  end

  # The generated files of world `name` that differ from the golden file of the same name.
  def golden_mismatches(name, files)
    names = Dir.children(File.join(FARGATE_STACK_GOLDEN_DIR, name)).sort
    differing = names.reject { |file| files[file] == File.read(File.join(FARGATE_STACK_GOLDEN_DIR, name, file)) }
    differing.map { |file| "#{name}/#{file}" }
  end

  def policy_names(role) = role["Properties"]["Policies"].map { |policy| policy["PolicyName"] }

  def template_of(files) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(files["template.yaml"])

  describe "a world that sets none of the multi-container settings" do
    FARGATE_STACK_SINGLE_WORLDS.each_key do |name|
      it "renders the #{name} world as its golden files, and the template is valid YAML", :aggregate_failures do
        files, stderr = single_world(name)
        expect(files).not_to be_nil, stderr

        expect(files.keys - ["Makefile"]).to match_array(Dir.children(File.join(FARGATE_STACK_GOLDEN_DIR, name)))
        expect(golden_mismatches(name, files)).to be_empty
        expect { template_of(files) }.not_to raise_error
      end
    end

    it "indents the Google sign-in policy and environment when the domain has a client id", :aggregate_failures do
      resources = template_of(single_world("aurora_oauth").first)["Resources"]
      definition = resources.fetch("WidgetShopServiceTaskDefinition")["Properties"]["ContainerDefinitions"].first

      expect(policy_names(resources.fetch("WidgetShopServiceTaskRole"))).to include("GoogleOauthSecretRead")
      expect(definition["Environment"].map { |entry| entry["Name"] }).to include("GOOGLE_OAUTH_SECRET_ID", "GOOGLE_REDIRECT_URI")
    end
  end

  describe "a world with several containers" do
    let(:generated) { cached("multi", FARGATE_STACK_MULTI_WORLD) }
    let(:files) { generated.first }
    let(:template) { template_of(files) }
    let(:resources) { template["Resources"] }

    def of_type(type) = resources.select { |_id, resource| resource["Type"] == type }

    def properties(id) = resources.fetch(id)["Properties"]

    def containers = properties("TaskDefinition")["ContainerDefinitions"]

    def distribution_config = properties("SiteDistribution")["DistributionConfig"]

    def domain_env_names = containers.first["Environment"].map { |entry| entry["Name"] }

    def domain_env_value(name) = containers.first["Environment"].find { |entry| entry["Name"] == name }["Value"]

    it "generates" do
      expect(files).not_to be_nil, generated.last
    end

    it "declares the ids the world fixed, not ids derived from the stack name", :aggregate_failures do
      expect(resources.keys).to include("Alb", "Cluster", "Service", "Listener", "SessionSecret", "SiteDistribution",
                                        "ComputeIngressFromAlb")
      expect(resources.keys.grep(/ScratchFixture/)).to be_empty
    end

    it "runs one task with the domain container first and one container per added entry", :aggregate_failures do
      expect(containers.map { |c| c["Name"] }).to eq(%w[domain website cms])
      expect(containers.map { |c| c["Essential"] }).to eq([true, true, true])
      expect(containers.map { |c| c["Image"] }).to eq(FARGATE_STACK_IMAGES)
      expect(properties("TaskDefinition")["Family"]).to eq("acme-platform")
    end

    it "gives each container its own repository and image-tag parameter, and drops the single ImageTag", :aggregate_failures do
      repositories = of_type("AWS::ECR::Repository").transform_values { |r| r["Properties"]["RepositoryName"] }

      expect(repositories).to eq("DomainRepository" => "acme-platform-domain", "WebsiteRepository" => "acme-platform-website",
                                 "CmsRepository" => "acme-platform-cms")
      expect(template["Parameters"].keys).to include("DomainImageTag", "WebsiteImageTag", "CmsImageTag")
      expect(template["Parameters"].keys).not_to include("ImageTag")
    end

    it "passes each added container its own environment and secrets", :aggregate_failures do
      containers = resources.fetch("TaskDefinition")["Properties"]["ContainerDefinitions"].to_h { |c| [c["Name"], c] }
      website_env = containers["website"]["Environment"].to_h { |e| [e["Name"], e["Value"]] }

      expect(website_env).to include("PORT" => "8080", "CDN_ORIGIN_SECRET" => { "Ref" => "CdnOriginSecret" })
      expect(containers["website"]["Secrets"]).to eq([{ "Name" => "AUTH_SECRET", "ValueFrom" => { "Ref" => "SessionSecret" } }])
      expect(containers["cms"]["PortMappings"]).to eq([{ "ContainerPort" => 8081 }])
    end

    it "gives every load-balanced container a target group with its own health check and drain delay", :aggregate_failures do
      groups = of_type("AWS::ElasticLoadBalancingV2::TargetGroup").transform_values { |g| g["Properties"] }

      expect(groups.keys).to match_array(%w[DomainTargetGroup WebsiteTargetGroup CmsTargetGroup])
      expect(groups["CmsTargetGroup"]).to include("HealthCheckPath" => "/cms/api/access", "Port" => 8081)
      expect(groups.values.map { |g| g["TargetGroupAttributes"] }.uniq).to eq(FARGATE_STACK_DRAIN)
    end

    it "sends the listener's default to the default container and routes the rest by path with priorities", :aggregate_failures do
      rules = of_type("AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(properties("Listener")["DefaultActions"].first["TargetGroupArn"]).to eq("Ref" => "WebsiteTargetGroup")
      expect(rules.map { |r| r["Priority"] }).to eq([10, 20, 21])
      expect(rules.map { |r| r["Conditions"].first["Values"] }).to eq(FARGATE_STACK_ROUTE_PATHS)
      expect(rules.map { |r| r["Actions"].first["TargetGroupArn"]["Ref"] }).to eq(FARGATE_STACK_RULE_TARGETS)
    end

    it "registers every container with the service, tunes it, and waits for the rules", :aggregate_failures do
      service = resources.fetch("Service")

      expect(service["Properties"]["LoadBalancers"].map { |l| l["ContainerName"] }).to eq(%w[domain website cms])
      expect(service["DependsOn"]).to eq(%w[Listener ListenerRuleCms ListenerRuleDomain ListenerRuleDomain2].sort)
      expect(service["Properties"]).to include(FARGATE_STACK_SERVICE_TUNING)
      expect(template["Parameters"]["DesiredCount"]).to eq("Type" => "Number", "Default" => 0)
    end

    it "opens the compute security group to the load balancer across every container's port", :aggregate_failures do
      rule = resources.fetch("ComputeIngressFromAlb")["Properties"]

      expect([rule["FromPort"], rule["ToPort"]]).to eq([8080, 8082])
      description = resources.fetch("AlbSecurityGroup")["Properties"]["GroupDescription"]
      expect(description).to eq("acme platform ALB, HTTP from the CDN only")
    end

    it "describes the distribution: its retention, aliases and certificate", :aggregate_failures do
      expect(resources.fetch("SiteDistribution")).to include("DeletionPolicy" => "Retain", "UpdateReplacePolicy" => "Retain")
      expect(distribution_config["Aliases"]).to eq(%w[www.example.com example.com])
      expect(distribution_config["ViewerCertificate"]).to include("SslSupportMethod" => "sni-only")
    end

    it "describes the distribution's origins and the origin secret header", :aggregate_failures do
      origins = distribution_config["Origins"]

      expect(origins.map { |o| o["Id"] }).to eq(%w[AlbOrigin AssetsOrigin])
      expect(origins.first["OriginCustomHeaders"]).to eq(FARGATE_STACK_ORIGIN_HEADERS)
      expect(origins.first["CustomOriginConfig"]).to eq(FARGATE_STACK_ORIGIN_CONFIG)
      expect(template["Parameters"]["CdnOriginSecret"]).to include("NoEcho" => true)
    end

    it "describes the distribution's ordered behaviors", :aggregate_failures do
      behaviors = distribution_config["CacheBehaviors"].map { |b| [b["PathPattern"], b["TargetOriginId"]] }

      expect(behaviors).to eq([["/_static/*", "AlbOrigin"], ["/api/*", "AlbOrigin"], ["/videos/*", "AssetsOrigin"]])
      expect(distribution_config["DefaultCacheBehavior"]["CachePolicyId"]).to eq("e0fe29ef-0768-4698-8260-aa7c8d3abae0")
    end

    it "adds the bucket, the generated secret and the extra secret name", :aggregate_failures do
      expect(resources.keys).to include("MediaBucket", "MediaBucketPolicy", "CmsSecret")
      expect(resources.fetch("SessionSecret")["Properties"]).to include("Name" => "acme-platform/session-secret")
      expect(resources.fetch("MediaBucket")["Properties"]["BucketName"]).to eq("Fn::Sub" => "acme-platform-media-${AWS::AccountId}")
    end

    it "grants the extra policies to the task role and the execution role, plus the exec-command policy", :aggregate_failures do
      task_policies = resources.fetch("TaskRole")["Properties"]["Policies"].map { |p| p["PolicyName"] }
      execution_policies = resources.fetch("ExecutionRole")["Properties"]["Policies"].map { |p| p["PolicyName"] }

      expect(task_policies).to include("SharedDatabaseSecretRead", "SessionSecretRead", "MediaAccess", "EcsExecDebug")
      expect(task_policies).not_to include("DbSecretRead")
      expect(execution_policies).to eq(["SessionSecretInject"])
    end

    it "wires alerting: a topic with an email subscription, and the alarms", :aggregate_failures do
      expect(properties("AlertsTopic")["TopicName"]).to eq("acme-platform-alerts")
      expect(properties("AlertsTopicEmailSubscription")).to include("Protocol" => "email", "Endpoint" => "ops@example.com")
      expect(of_type("AWS::CloudWatch::Alarm").keys).to match_array(FARGATE_STACK_ALARMS)
      expect(properties("AlbTarget5xxAlarm")["AlarmDescription"]).to eq("Targets are returning 5xx responses.")
    end

    it "wires the CloudFront metrics subscription and a warmer", :aggregate_failures do
      expect(resources.keys).to include(*FARGATE_STACK_WARMER_RESOURCES)
      expect(properties("SyntheticCheckFailuresAlarm")["TreatMissingData"]).to eq("breaching")
      expect(properties("WarmerFunction")["Code"]["ZipFile"]).to include('["/","/about.html"]', "Acme/Synthetic")
      expect(properties("CloudFront5xxAlarm")).not_to have_key("Period")
      expect(properties("WarmerSchedule")["Description"]).to eq("Runs the site check.")
    end

    it "removes and replaces the default domain environment variables the world names", :aggregate_failures do
      expect(domain_env_names).not_to include("HECKS_ERA", "HECKS_WEB")
      expect(domain_env_names.tally.values.uniq).to eq([1])
      expect(domain_env_names).to include("HECKS_SESSION_COOKIE", "SITE_URL", "BIND", "HECKS_SERVE_MODE")
      expect(domain_env_value("DB_NAME")).to eq("Ref" => "OwningDatabaseName")
      expect(domain_env_value("HECKS_WASM_PATH")).to eq("/app/#{FARGATE_STACK_FIXTURE_NAME}.wasm")
    end

    it "outputs the cluster, the service, each repository and the extra outputs" do
      expect(template["Outputs"].keys).to include(
        "ClusterName", "ServiceName", "DomainRepositoryUri", "WebsiteRepositoryUri", "CmsRepositoryUri",
        "AlertsTopicArn", "MediaBucketName", "ServiceUrl", "CloudFrontDomain"
      )
    end

    it "installs the host and its sidecars where the world says, from the build directory it names", :aggregate_failures do
      dockerfile = files["Dockerfile"]

      name = FARGATE_STACK_FIXTURE_NAME
      expect(dockerfile).to include("COPY domain-build/#{name}-host /app/#{name}-host")
      expect(dockerfile).to include("COPY domain-build/#{name}.wasm /app/#{name}.wasm")
      expect(dockerfile).to include("CMD [\"/app/#{FARGATE_STACK_FIXTURE_NAME}-host\"]")
    end

    it "adds the world's resources to, and replaces the derived ids of, the single-container template", :aggregate_failures do
      single, = cached("default", FARGATE_STACK_SINGLE_WORLDS.fetch("default"))
      report = Hecks::Projections::Deploy::TemplateDiff.diff(single["template.yaml"], files["template.yaml"])

      expect(report.sections["Resources"].added.map(&:first)).to include("WebsiteRepository", "CmsTargetGroup", "AlertsTopic")
      expect(report.sections["Resources"].removed.map(&:first)).to include("ScratchFixtureServiceAlb")
    end
  end

  describe "a world with a mistake in the multi-container settings" do
    it "is refused with the setting's name, before any file is written", :aggregate_failures do
      files, stderr = cached("clash", FARGATE_STACK_CLASH_WORLD)

      expect(files).to be_nil
      expect(stderr).to include("deployed_to(\"AwsFargate\")").and include("declared more than once")
    end
  end
end
