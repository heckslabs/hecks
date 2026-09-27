require "tmpdir"
require "fileutils"
require "open3"
require "hecks/projections/deploy/template_diff"

# The AwsFargate template generator's two promises: a world that sets none of the multi-container
# settings still renders exactly the files it always did (compared against files generated before
# those settings existed), and a world that sets them renders one task with several containers,
# routed by path behind one load balancer and one distribution.
#
# Each world is generated once through `bin/project_deploy`, the real entry point, and read back off
# disk. The multi-container world uses neutral names throughout.
RSpec.describe "bin/project_deploy — a multi-container deployed_to(\"AwsFargate\") stack", :io do
  FARGATE_STACK_ROOT_DIR = File.expand_path("..", __dir__)
  FARGATE_STACK_GOLDEN_DIR = File.join(__dir__, "fixtures", "deploy_fargate_golden")
  FARGATE_STACK_FIXTURE_NAME = "scratch_fixture".freeze
  # The generator's own comments name one deployment; the golden files hold that name masked, so no
  # fixture stores it.
  FARGATE_STACK_MASKED_NAME = Regexp.new(%w[life adelics].join, Regexp::IGNORECASE)

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

  def generate(world_body, env_local: nil)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, FARGATE_STACK_FIXTURE_NAME)
      bluebook_dir = File.join(domain, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{FARGATE_STACK_FIXTURE_NAME}.bluebook"), FARGATE_STACK_BLUEBOOK)
      File.write(File.join(bluebook_dir, "#{FARGATE_STACK_FIXTURE_NAME}.world"), world_body)
      File.write(File.join(domain, ".env.local"), env_local) if env_local
      out = File.join(dir, "out")
      _stdout, stderr, status = Open3.capture3("ruby", File.join(FARGATE_STACK_ROOT_DIR, "bin/project_deploy"), domain,
                                               "--out=#{out}")
      return [nil, stderr] unless status.success?

      files = Dir.children(out).to_h do |name|
        [name, File.read(File.join(out, name)).gsub(domain, "<domain>").gsub(FARGATE_STACK_ROOT_DIR, "<root>")]
      end
      [files, stderr]
    end
  end

  def cached(key, world_body, **options)
    FargateStackGeneratedWorlds.fetch(key) { generate(world_body, **options) }
  end

  def template_of(files) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(files["template.yaml"])

  describe "a world that sets none of the multi-container settings" do
    FARGATE_STACK_SINGLE_WORLDS.each_key do |name|
      it "renders the #{name} world exactly as it was rendered before those settings existed" do
        env_local = name == "aurora_oauth" ? "GOOGLE_CLIENT_ID=abc\n" : nil
        files, stderr = cached(name, FARGATE_STACK_SINGLE_WORLDS.fetch(name), env_local: env_local)
        expect(files).not_to be_nil, stderr

        golden_names = Dir.children(File.join(FARGATE_STACK_GOLDEN_DIR, name)).sort
        expect(files.keys - ["Makefile"]).to match_array(golden_names)
        golden_names.each do |file|
          golden = File.read(File.join(FARGATE_STACK_GOLDEN_DIR, name, file))
          expect(files[file].gsub(FARGATE_STACK_MASKED_NAME, "<client>")).to eq(golden),
                                                                             "#{name}/#{file} differs from its golden file"
        end
      end
    end
  end

  describe "a world with several containers" do
    let(:generated) { cached("multi", FARGATE_STACK_MULTI_WORLD) }
    let(:files) { generated.first }
    let(:template) { template_of(files) }
    let(:resources) { template["Resources"] }

    def of_type(type) = resources.select { |_id, resource| resource["Type"] == type }

    it "generates" do
      expect(files).not_to be_nil, generated.last
    end

    it "declares the ids the world fixed, not ids derived from the stack name" do
      expect(resources.keys).to include("Alb", "Cluster", "Service", "Listener", "SessionSecret", "SiteDistribution",
                                        "ComputeIngressFromAlb")
      expect(resources.keys.grep(/ScratchFixture/)).to be_empty
    end

    it "runs one task with the domain container first and one container per added entry" do
      task = resources.fetch("TaskDefinition")["Properties"]
      containers = task["ContainerDefinitions"]

      expect(containers.map { |c| c["Name"] }).to eq(%w[domain website cms])
      expect(containers.map { |c| c["Essential"] }).to eq([true, true, true])
      expect(containers.map { |c| c["Image"] }).to eq(
        [{ "Fn::Sub" => "${DomainRepository.RepositoryUri}:${DomainImageTag}" },
         { "Fn::Sub" => "${WebsiteRepository.RepositoryUri}:${WebsiteImageTag}" },
         { "Fn::Sub" => "${CmsRepository.RepositoryUri}:${CmsImageTag}" }]
      )
      expect(task["Family"]).to eq("acme-platform")
    end

    it "gives each container its own repository and image-tag parameter, and drops the single ImageTag" do
      repositories = of_type("AWS::ECR::Repository").transform_values { |r| r["Properties"]["RepositoryName"] }

      expect(repositories).to eq("DomainRepository" => "acme-platform-domain", "WebsiteRepository" => "acme-platform-website",
                                 "CmsRepository" => "acme-platform-cms")
      expect(template["Parameters"].keys).to include("DomainImageTag", "WebsiteImageTag", "CmsImageTag")
      expect(template["Parameters"].keys).not_to include("ImageTag")
    end

    it "passes each added container its own environment and secrets" do
      containers = resources.fetch("TaskDefinition")["Properties"]["ContainerDefinitions"].to_h { |c| [c["Name"], c] }
      website_env = containers["website"]["Environment"].to_h { |e| [e["Name"], e["Value"]] }

      expect(website_env).to include("PORT" => "8080", "CDN_ORIGIN_SECRET" => { "Ref" => "CdnOriginSecret" })
      expect(containers["website"]["Secrets"]).to eq([{ "Name" => "AUTH_SECRET", "ValueFrom" => { "Ref" => "SessionSecret" } }])
      expect(containers["cms"]["PortMappings"]).to eq([{ "ContainerPort" => 8081 }])
    end

    it "gives every load-balanced container a target group with its own health check and drain delay" do
      groups = of_type("AWS::ElasticLoadBalancingV2::TargetGroup").transform_values { |g| g["Properties"] }

      expect(groups.keys).to match_array(%w[DomainTargetGroup WebsiteTargetGroup CmsTargetGroup])
      expect(groups["CmsTargetGroup"]).to include("HealthCheckPath" => "/cms/api/access", "Port" => 8081)
      expect(groups.values.map do |g|
        g["TargetGroupAttributes"]
      end.uniq).to eq([[{ "Key" => "deregistration_delay.timeout_seconds", "Value" => "30" }]])
    end

    it "sends the listener's default to the default container and routes the rest by path with priorities" do
      listener = resources.fetch("Listener")["Properties"]
      rules = of_type("AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(listener["DefaultActions"].first["TargetGroupArn"]).to eq("Ref" => "WebsiteTargetGroup")
      expect(rules.map { |r| r["Priority"] }).to eq([10, 20, 21])
      expect(rules.map { |r| r["Conditions"].first["Values"] }).to eq(
        [["/cms/*"], ["/registrations", "/registrations/*", "/webhooks/*"], ["/login", "/logout", "/auth/*"]]
      )
      expect(rules.map do |r|
        r["Actions"].first["TargetGroupArn"]["Ref"]
      end).to eq(%w[CmsTargetGroup DomainTargetGroup DomainTargetGroup])
    end

    it "registers every container with the service, tunes it, and waits for the rules" do
      service = resources.fetch("Service")

      expect(service["Properties"]["LoadBalancers"].map { |l| l["ContainerName"] }).to eq(%w[domain website cms])
      expect(service["DependsOn"]).to eq(%w[Listener ListenerRuleCms ListenerRuleDomain ListenerRuleDomain2].sort)
      expect(service["Properties"]).to include(
        "EnableExecuteCommand" => true, "HealthCheckGracePeriodSeconds" => 10, "DesiredCount" => { "Ref" => "DesiredCount" }
      )
      expect(template["Parameters"]["DesiredCount"]).to eq("Type" => "Number", "Default" => 0)
    end

    it "opens the compute security group to the load balancer across every container's port" do
      rule = resources.fetch("ComputeIngressFromAlb")["Properties"]

      expect([rule["FromPort"], rule["ToPort"]]).to eq([8080, 8082])
      description = resources.fetch("AlbSecurityGroup")["Properties"]["GroupDescription"]
      expect(description).to eq("acme platform ALB, HTTP from the CDN only")
    end

    it "describes the distribution: aliases, certificate, origins, ordered behaviors, and the origin secret header" do
      distribution = resources.fetch("SiteDistribution")
      config = distribution["Properties"]["DistributionConfig"]

      expect(distribution).to include("DeletionPolicy" => "Retain", "UpdateReplacePolicy" => "Retain")
      expect(config["Aliases"]).to eq(%w[www.example.com example.com])
      expect(config["ViewerCertificate"]).to include("SslSupportMethod" => "sni-only")
      expect(config["Origins"].map { |o| o["Id"] }).to eq(%w[AlbOrigin AssetsOrigin])
      expect(config["Origins"].first["OriginCustomHeaders"]).to eq([{ "HeaderName"  => "X-Origin-Secret",
                                                                      "HeaderValue" => { "Ref" => "CdnOriginSecret" } }])
      expect(config["Origins"].first["CustomOriginConfig"]).to eq("OriginProtocolPolicy" => "http-only",
                                                                  "OriginSSLProtocols"   => ["TLSv1.2"])
      expect(config["CacheBehaviors"].map { |b| [b["PathPattern"], b["TargetOriginId"]] }).to eq(
        [["/_static/*", "AlbOrigin"], ["/api/*", "AlbOrigin"], ["/videos/*", "AssetsOrigin"]]
      )
      expect(config["DefaultCacheBehavior"]["CachePolicyId"]).to eq("e0fe29ef-0768-4698-8260-aa7c8d3abae0")
      expect(template["Parameters"]["CdnOriginSecret"]).to include("NoEcho" => true)
    end

    it "adds the bucket, the generated secret and the extra secret name" do
      expect(resources.keys).to include("MediaBucket", "MediaBucketPolicy", "CmsSecret")
      expect(resources.fetch("SessionSecret")["Properties"]).to include("Name" => "acme-platform/session-secret")
      expect(resources.fetch("MediaBucket")["Properties"]["BucketName"]).to eq("Fn::Sub" => "acme-platform-media-${AWS::AccountId}")
    end

    it "grants the extra policies to the task role and the execution role, plus the exec-command policy" do
      task_policies = resources.fetch("TaskRole")["Properties"]["Policies"].map { |p| p["PolicyName"] }
      execution_policies = resources.fetch("ExecutionRole")["Properties"]["Policies"].map { |p| p["PolicyName"] }

      expect(task_policies).to include("SharedDatabaseSecretRead", "SessionSecretRead", "MediaAccess", "EcsExecDebug")
      expect(task_policies).not_to include("DbSecretRead")
      expect(execution_policies).to eq(["SessionSecretInject"])
    end

    it "wires alerting: a topic with an email subscription, alarms, the CloudFront metrics subscription and a warmer" do
      alarms = of_type("AWS::CloudWatch::Alarm").keys

      expect(resources.fetch("AlertsTopic")["Properties"]["TopicName"]).to eq("acme-platform-alerts")
      expect(resources.fetch("AlertsTopicEmailSubscription")["Properties"]).to include("Protocol" => "email",
                                                                                       "Endpoint" => "ops@example.com")
      expect(alarms).to match_array(%w[AlbTarget5xxAlarm DomainTargetUnhealthyAlarm WebsiteTargetUnhealthyAlarm
                                       CmsTargetUnhealthyAlarm CloudFront5xxAlarm SyntheticCheckFailuresAlarm])
      expect(resources.keys).to include("CloudFrontMonitoringSubscription", "WarmerFunction", "WarmerSchedule", "WarmerRole",
                                        "SchedulerInvokeRole")
      expect(resources.fetch("SyntheticCheckFailuresAlarm")["Properties"]["TreatMissingData"]).to eq("breaching")
      expect(resources.fetch("WarmerFunction")["Properties"]["Code"]["ZipFile"]).to include('["/","/about.html"]',
                                                                                            "Acme/Synthetic")
      expect(resources.fetch("CloudFront5xxAlarm")["Properties"]).not_to have_key("Period")
      expect(resources.fetch("AlbTarget5xxAlarm")["Properties"]["AlarmDescription"]).to eq("Targets are returning 5xx responses.")
      expect(resources.fetch("WarmerSchedule")["Properties"]["Description"]).to eq("Runs the site check.")
    end

    it "removes and replaces the default domain environment variables the world names" do
      env = resources.fetch("TaskDefinition")["Properties"]["ContainerDefinitions"].first["Environment"]
      names = env.map { |e| e["Name"] }

      expect(names).not_to include("HECKS_ERA", "HECKS_WEB")
      expect(names.tally.values.uniq).to eq([1])
      expect(names).to include("HECKS_SESSION_COOKIE", "SITE_URL", "BIND", "HECKS_SERVE_MODE")
      expect(env.find { |e| e["Name"] == "DB_NAME" }["Value"]).to eq("Ref" => "OwningDatabaseName")
      expect(env.find { |e| e["Name"] == "HECKS_WASM_PATH" }["Value"]).to eq("/app/#{FARGATE_STACK_FIXTURE_NAME}.wasm")
    end

    it "outputs the cluster, the service, each repository and the extra outputs" do
      expect(template["Outputs"].keys).to include(
        "ClusterName", "ServiceName", "DomainRepositoryUri", "WebsiteRepositoryUri", "CmsRepositoryUri",
        "AlertsTopicArn", "MediaBucketName", "ServiceUrl", "CloudFrontDomain"
      )
    end

    it "installs the host and its sidecars where the world says, from the build directory it names" do
      dockerfile = files["Dockerfile"]

      name = FARGATE_STACK_FIXTURE_NAME
      expect(dockerfile).to include("COPY domain-build/#{name}-host /app/#{name}-host")
      expect(dockerfile).to include("COPY domain-build/#{name}.wasm /app/#{name}.wasm")
      expect(dockerfile).to include("CMD [\"/app/#{FARGATE_STACK_FIXTURE_NAME}-host\"]")
    end

    it "adds the world's resources to, and replaces the derived ids of, the single-container template" do
      single, = cached("default", FARGATE_STACK_SINGLE_WORLDS.fetch("default"))
      report = Hecks::Projections::Deploy::TemplateDiff.diff(single["template.yaml"], files["template.yaml"])

      expect(report.sections["Resources"].added.map(&:first)).to include("WebsiteRepository", "CmsTargetGroup", "AlertsTopic")
      expect(report.sections["Resources"].removed.map(&:first)).to include("ScratchFixtureServiceAlb")
    end
  end

  describe "a world with a mistake in the multi-container settings" do
    it "is refused with the setting's name, before any file is written" do
      files, stderr = cached("clash", <<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsFargate") do
            region "us-east-1"
            logical_ids alb: "Cluster", cluster: "Cluster"
          end
        end
      WORLD

      expect(files).to be_nil
      expect(stderr).to include("deployed_to(\"AwsFargate\")").and include("declared more than once")
    end
  end
end
