require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require "openssl"
require "base64"
require "json"

# Per-branch preview stacks for `deployed_to("AwsFargate")`
# (`Hecks::Projections::Deploy::Preview`): structural assertions on the
# generated `preview.yaml`, behavior of the generated `preview.sh`, and the
# opt-in guarantee that a domain without a `preview` setting gets the files
# it always got.
RSpec.describe Hecks::Projections::Deploy::Preview do
  let(:main) do
    {
      infra_name: "widgets", stack_name: "hecks-widgets", stack_prefix: "hecks", region: "us-east-1",
      cpu: 256, memory: 512, db_name: "widgets", owner_stack: nil, name: "widgets", port: 8080,
      image: "widgets:latest", domain: "Widgets", web: "Rust", wasm_path: "/usr/local/bin/widgets.wasm",
      ir_path: "/usr/local/bin/widgets.ir.json", schema: nil
    }
  end
  let(:multi) do
    {
      containers: [
        { name: "site", port: 8080, paths: ["/app/*"], environment: { "SITE_URL" => "{{preview_url}}" } },
        { name: "admin", port: 8081, database: true, secrets: ["SIGNING_KEY_ARN"], paths: ["/admin/*"],
          health_check_path: "/admin/health" },
        { name: "core", port: 8082, host: true, default: true }
      ]
    }
  end

  def generate(preview, extra = {})
    described_class.call(deploy_settings: { preview: preview }.merge(extra), main: main)
  end

  def parsed(yaml) = YAML.safe_load(yaml, permitted_classes: [], aliases: true)

  def template(preview, extra = {}) = parsed(generate(preview, extra).fetch("preview.yaml"))

  def resources_of(doc, type)
    doc["Resources"].select { |_name, resource| resource["Type"] == type }
  end

  def containers_of(doc) = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"]

  def host_environment(doc) = containers_of(doc).first["Environment"]

  def by_name(env) = env.to_h { |e| [e["Name"], e["Value"]] }

  def container_environment(doc, name)
    by_name(containers_of(doc).find { |c| c["Name"] == name }["Environment"])
  end

  describe "opting in" do
    it "generates nothing without a preview setting", :aggregate_failures do
      expect(described_class.call(deploy_settings: {}, main: main)).to eq({})
      expect(described_class.call(deploy_settings: { preview: false }, main: main)).to eq({})
    end

    it "accepts `true` and an empty block as all defaults", :aggregate_failures do
      expect(generate(true).keys).to eq(%w[preview.yaml preview.sh])
      expect(generate({}).keys).to eq(%w[preview.yaml preview.sh])
    end
  end

  describe "the world's nested settings block" do
    def declared(&block)
      world = Hecks::Bluebook::DSL::WorldBuilder.build("Scratch") { deployed_to("AwsFargate", &block) }
      world.for_verb("deployed_to")
    end

    def declared_with_preview
      declared do
        region "us-east-1"
        preview do
          cpu 512
          containers [{ name: "web", port: 8080 }]
        end
      end
    end

    it "records a block as a nested Hash and a plain call as its argument", :aggregate_failures do
      settings = declared_with_preview

      expect(settings[:region]).to eq("us-east-1")
      expect(settings[:preview]).to eq(cpu: 512, containers: [{ name: "web", port: 8080 }])
    end

    it "records an empty block as an empty Hash, which still opts in", :aggregate_failures do
      settings = declared { preview { nil } }

      expect(settings[:preview]).to eq({})
      expect(described_class.requested?(settings)).to be(true)
    end

    it "keeps the hash-argument spelling working" do
      expect(declared { preview cpu: 512 }[:preview]).to eq(cpu: 512)
    end
  end

  describe "settings" do
    def settings(raw, extra = {})
      Hecks::Projections::Deploy::Preview::Settings.build(raw, deploy_settings: extra, main: main)
    end

    it "derives every name from the main stack by default" do
      s = settings({})

      expect([s.prefix, s.alb_prefix, s.owner_stack, s.database_stack, s.db_prefix]).to eq(
        ["hecks-widgets-preview", "widgetspv", "hecks-widgets", "hecks-widgets", "widgets"]
      )
    end

    it "protects the main database and sizes the task like the main stack by default", :aggregate_failures do
      s = settings({})

      expect(s.protected_databases).to include("widgets", "postgres")
      expect([s.cpu, s.memory, s.log_retention_days]).to eq([256, 512, 7])
    end

    it "borrows a Shared main stack's owner", :aggregate_failures do
      shared = Hecks::Projections::Deploy::Preview::Settings.build(
        {}, deploy_settings: {}, main: main.merge(owner_stack: "hecks-owner", db_name: "owner")
      )

      expect(shared.owner_stack).to eq("hecks-owner")
      expect(shared.protected_databases).to include("owner")
    end

    def overridden
      settings(prefix: "wid-pv", database_stack: "aurora-stack", database_endpoint_output: "ClusterEndpoint",
               database_secret_output: "SecretArn", cpu: 512, memory: 1024, session_cookie: "wid_session",
               protected_databases: ["keepme"], first_admin: false)
    end

    it "lets every name key be overridden", :aggregate_failures do
      s = overridden

      expect(s.prefix).to eq("wid-pv")
      expect([s.database_stack, s.database_endpoint_output, s.database_secret_output]).to eq(
        %w[aurora-stack ClusterEndpoint SecretArn]
      )
    end

    it "lets every sizing and access key be overridden", :aggregate_failures do
      s = overridden

      expect([s.cpu, s.memory, s.session_cookie, s.first_admin]).to eq([512, 1024, "wid_session", false])
      expect(s.protected_databases).to include("keepme")
    end

    it "refuses an unknown key, naming the known ones" do
      expect { settings(colour: "red") }.to raise_error(ArgumentError, /unknown preview setting.*colour.*known: prefix/)
    end

    it "refuses values that would break a name, a database or the script", :aggregate_failures do
      bad = { prefix: "Bad Prefix", db_prefix: "x; drop", alb_prefix: "waytoolongforalb", log_retention_days: 8,
              protected_branches: ["a b"], signup_path: "signups" }

      bad.each { |key, value| expect { settings(key => value) }.to raise_error(ArgumentError, /#{key}/) }
    end

    PREVIEW_SPEC_UNUSABLE_CONTAINERS = [
      [],
      [{ name: "a", port: 1 }, { name: "a", port: 2 }],
      [{ name: "a", port: 1 }, { name: "b", port: 1 }],
      [{ name: "a", port: 1, default: true }, { name: "b", port: 2, default: true }],
      [{ name: "a", port: 1, host: true }, { name: "b", port: 2, host: true }],
      [{ name: "Bad Name", port: 1 }],
      [{ name: "a" }],
      [{ name: "a", port: 1, image: "x y" }],
      [{ name: "a", port: 1, secrets: ["lowercase"] }]
    ].freeze

    it "refuses a container list that cannot be one task" do
      PREVIEW_SPEC_UNUSABLE_CONTAINERS.each do |containers|
        expect { settings(containers: containers) }.to raise_error(ArgumentError)
      end
    end

    it "reads a container list from the shared setting when the preview block gives none", :aggregate_failures do
      shared = { containers: [{ name: "only", port: 9000, host: true }] }
      s = settings({}, shared)

      expect(s.containers.map(&:name)).to eq(["only"])
      expect(s.default_container.name).to eq("only")
    end
  end

  describe "preview.yaml for one container" do
    let(:doc) { template({}) }

    PREVIEW_SPEC_SCRIPT_PARAMETERS = [
      "EnvName", "DbName", "OwningVpcId", "OwningSubnetAId", "OwningSubnetBId", "OwningPublicSubnetAId",
      "OwningPublicSubnetBId", "OwningSecurityGroupId", "OwningDatabaseEndpoint", "OwningDatabaseSecretArn",
      "WidgetsImageTag", "DesiredCount"
    ].freeze

    it "parses and declares the parameters preview.sh passes", :aggregate_failures do
      expect(doc["Parameters"].keys).to include(*PREVIEW_SPEC_SCRIPT_PARAMETERS)
      expect(doc["Parameters"]["DesiredCount"]["Default"]).to eq(0)
    end

    it "constrains EnvName and DbName by pattern", :aggregate_failures do
      env = Regexp.new(doc["Parameters"]["EnvName"]["AllowedPattern"])
      db = Regexp.new(doc["Parameters"]["DbName"]["AllowedPattern"])

      accepted = ->(pattern, values) { values.grep(pattern) }

      expect(accepted.call(env, ["feat-x", "a1", "a", "-x", "x-", "Upper", "a" * 21])).to eq(%w[feat-x a1 a])
      expect(accepted.call(db, ["widgets_pv_x", "1abc", "a-b", "a;b"])).to eq(%w[widgets_pv_x])
    end

    it "owns one repository, one target group, one service and one distribution per branch", :aggregate_failures do
      expect(resources_of(doc, "AWS::ECR::Repository").size).to eq(1)
      expect(resources_of(doc, "AWS::ElasticLoadBalancingV2::TargetGroup").size).to eq(1)
      expect(resources_of(doc, "AWS::ECS::Service").size).to eq(1)
      expect(resources_of(doc, "AWS::CloudFront::Distribution").size).to eq(1)
      expect(resources_of(doc, "AWS::ElasticLoadBalancingV2::ListenerRule")).to be_empty
    end

    it "has no alarms, topics or schedules" do
      types = doc["Resources"].values.map { |r| r["Type"] }

      expect(types.grep(/CloudWatch::Alarm|SNS::|Events::Rule|Lambda::/)).to be_empty
    end

    PREVIEW_SPEC_HOST_ENVIRONMENT = {
      "HECKS_DOMAIN" => "Widgets", "HECKS_SERVE_MODE" => "1", "PORT" => "8080", "DB_NAME" => "DbName",
      "SESSION_SECRET_ARN" => "SessionSecret", "DB_HOST" => "OwningDatabaseEndpoint",
      "DB_SECRET_ARN" => "OwningDatabaseSecretArn", "HECKS_WASM_PATH" => "/usr/local/bin/widgets.wasm"
    }.freeze

    it "makes a per-branch secret and points the host at it", :aggregate_failures do
      env = host_environment(doc)
      expect(resources_of(doc, "AWS::SecretsManager::Secret").keys).to eq(["SessionSecret"])

      expect(by_name(env)).to include(PREVIEW_SPEC_HOST_ENVIRONMENT)
      expect(by_name(env)).not_to have_key("HECKS_SCHEMA")
      expect(env.map { |e| e["Name"] }.uniq.size).to eq(env.size)
    end

    def configured_template
      parsed(
        described_class.call(deploy_settings: { preview: { session_cookie: "wid_session" } },
                             main:            main.merge(schema: "widgets_schema")).fetch("preview.yaml")
      )
    end

    it "sets the schema and the session cookie when configured" do
      env = by_name(host_environment(configured_template))

      expect(env).to include("HECKS_SCHEMA" => "widgets_schema", "HECKS_SESSION_COOKIE" => "wid_session")
    end

    it "keeps the ALB reachable only from CloudFront and the shared group only from the ALB", :aggregate_failures do
      alb_sg = doc["Resources"]["AlbSecurityGroup"]["Properties"]["SecurityGroupIngress"].first
      ingress = resources_of(doc, "AWS::EC2::SecurityGroupIngress").values.first["Properties"]

      expect(alb_sg["SourcePrefixListId"]).to eq("pl-3b927c52")
      expect(alb_sg).not_to have_key("CidrIp")
      expect(ingress).to include("GroupId" => "OwningSecurityGroupId", "SourceSecurityGroupId" => "AlbSecurityGroup")
    end

    it "caches nothing at the distribution" do
      behavior = resources_of(doc, "AWS::CloudFront::Distribution").values.first["Properties"]["DistributionConfig"]["DefaultCacheBehavior"]

      expect(behavior["CachePolicyId"]).to eq("4135ea2d-6df8-44a3-9df3-4b5a84be39ad")
    end

    it "sizes the task from the main stack and lets the preview override it", :aggregate_failures do
      expect(doc["Resources"]["TaskDefinition"]["Properties"]).to include("Cpu" => "256", "Memory" => "512")

      bigger = template(cpu: 1024, memory: 3072)
      expect(bigger["Resources"]["TaskDefinition"]["Properties"]).to include("Cpu" => "1024", "Memory" => "3072")
    end

    it "names the ALB within the 32-character limit for the longest env name" do
      name = doc["Resources"]["Alb"]["Properties"]["Name"].sub("${EnvName}", "a" * 20)

      expect(name.length).to be <= 32
    end
  end

  describe "the database task" do
    let(:task) { template({})["Resources"]["DbInitTaskDefinition"]["Properties"]["ContainerDefinitions"].first }

    it "runs a Postgres client image with the credentials as container secrets, never as plain values", :aggregate_failures do
      expect(task["Image"]).to eq("public.ecr.aws/docker/library/postgres:16-alpine")
      expect(task["Secrets"].map { |s| s["Name"] }).to eq(%w[PGUSER PGPASSWORD])
      expect(task["Environment"].map { |e| e["Name"] }).not_to include("PGPASSWORD")
    end

    it "refuses the main database and the maintenance databases" do
      protected = task["Environment"].find { |e| e["Name"] == "PROTECTED_DATABASES" }["Value"].split

      expect(protected).to include("widgets", "postgres", "template0", "template1")
    end

    it "runs a script that validates the name, creates idempotently, and can drop", :aggregate_failures do
      script = task["Command"].last

      expect(script).to include("SELECT 1 FROM pg_database", "CREATE DATABASE", "DROP DATABASE", "already exists")
      expect(script).to include("*[!a-z0-9_]*")
    end

    it "can be given another image" do
      other = template(db_init_image: "registry.example/psql:1")["Resources"]["DbInitTaskDefinition"]

      expect(other["Properties"]["ContainerDefinitions"].first["Image"]).to eq("registry.example/psql:1")
    end

    it "is a script `sh` can parse, with the case/for/if structure closed" do
      script = task["Command"].last
      out, status = Open3.capture2e("sh", "-n", stdin_data: script)

      expect(status).to be_success, out
    end
  end

  describe "preview.yaml for several containers" do
    let(:doc) { template(multi) }

    it "gives each container its own repository, image-tag parameter and log prefix", :aggregate_failures do
      expect(resources_of(doc, "AWS::ECR::Repository").keys).to eq(%w[SiteRepository AdminRepository CoreRepository])
      expect(doc["Parameters"].keys).to include("SiteImageTag", "AdminImageTag", "CoreImageTag")
      containers = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"]

      expect(containers.map { |c| c["Name"] }).to eq(%w[site admin core])
      expect(containers.map { |c| c["LogConfiguration"]["Options"]["awslogs-stream-prefix"] }).to eq(%w[site admin core])
    end

    it "sends unmatched requests to the default container and paths to the others", :aggregate_failures do
      listener = doc["Resources"]["Listener"]["Properties"]
      rules = resources_of(doc, "AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(listener["DefaultActions"].first["TargetGroupArn"]).to eq("CoreTargetGroup")
      expect(rules.map { |r| r["Conditions"].first["Values"] }).to eq([["/app/*"], ["/admin/*"]])
      expect(rules.map { |r| r["Priority"] }).to eq([10, 20])
    end

    it "registers every routed container with the service and the shared security group", :aggregate_failures do
      balancers = doc["Resources"]["Service"]["Properties"]["LoadBalancers"]

      expect(balancers.map { |b| b["ContainerName"] }).to eq(%w[site admin core])
      expect(resources_of(doc, "AWS::EC2::SecurityGroupIngress").size).to eq(3)
      expect(doc["Resources"]["Service"]["DependsOn"]).to include("Listener", "ListenerRuleSite1", "ListenerRuleAdmin1")
    end

    it "gives the host the domain environment and only the database containers the database environment", :aggregate_failures do
      expect(container_environment(doc, "core")).to include("HECKS_DOMAIN", "DB_NAME")
      expect(container_environment(doc, "admin")).to include("DB_NAME")
      expect(container_environment(doc, "admin")).not_to include("HECKS_DOMAIN")
      expect(container_environment(doc, "site")).not_to include("DB_NAME")
    end

    it "routes the signup path to a host that is not the default" do
      other = template(containers: [{ name: "site", port: 8080, default: true },
                                    { name: "core", port: 8082, host: true }])
      rules = resources_of(other, "AWS::ElasticLoadBalancingV2::ListenerRule").values

      expect(rules.map { |r| r["Properties"]["Conditions"].first["Values"] }).to eq([["/signups"]])
    end

    it "generates a secret per declared name and lets the task role read it", :aggregate_failures do
      role = doc["Resources"]["TaskRole"]["Properties"]["Policies"].find { |p| p["PolicyName"] == "PreviewSecretRead" }
      env = containers_of(doc)[1]["Environment"]

      expect(resources_of(doc, "AWS::SecretsManager::Secret").keys).to eq(%w[SessionSecret AdminSigningKeySecret])
      expect(role["PolicyDocument"]["Statement"].first["Resource"]).to eq(%w[SessionSecret AdminSigningKeySecret])
      expect(env.find { |e| e["Name"] == "SIGNING_KEY_ARN" }["Value"]).to eq("AdminSigningKeySecret")
    end

    it "renders the preview URL token as an intrinsic against the distribution" do
      raw = generate(multi).fetch("preview.yaml")

      expect(raw).to include('Value: !Sub "https://${PreviewDistribution.DomainName}"')
    end

    it "splits more than five paths across rules with distinct priorities", :aggregate_failures do
      many = template(containers: [{ name: "a", port: 1, default: true },
                                   { name: "b", port: 2, paths: (1..7).map { |i| "/p#{i}/*" } }])
      rules = resources_of(many, "AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(rules.map { |r| r["Conditions"].first["Values"].size }).to eq([5, 2])
      expect(rules.map { |r| r["Priority"] }.uniq.size).to eq(2)
    end

    it "gives a container with no route no target group and no port mapping", :aggregate_failures do
      sidecar = template(containers: [{ name: "a", port: 1, default: true }, { name: "worker", port: 2 }])
      definition = sidecar["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"].last

      expect(resources_of(sidecar, "AWS::ElasticLoadBalancingV2::TargetGroup").keys).to eq(["ATargetGroup"])
      expect(definition).not_to have_key("PortMappings")
    end
  end

  describe "preview.sh", :io do
    let(:dir) { Dir.mktmpdir("preview-script") }
    let(:script) { File.join(dir, "preview.sh") }
    let(:text) { File.read(script) }

    before { File.write(script, generate(multi).fetch("preview.sh")) }
    after { FileUtils.rm_rf(dir) }

    def run(*args, env: {})
      Open3.capture3(env, "bash", script, *args)
    end

    def expect_valid_bash
      out, status = Open3.capture2e("bash", "-n", script)

      expect(status).to be_success, out
    end

    def minted_token(*args)
      out, err, status = Open3.capture3("bash", "-c", "source #{script}; mint_token #{args.join(" ")}")
      expect(status).to be_success, err
      out.strip.split(".")
    end

    it "is valid bash" do
      expect_valid_bash
    end

    it "passes shellcheck when it is installed" do
      skip "shellcheck is not installed" unless system("command -v shellcheck >/dev/null 2>&1")

      out, status = Open3.capture2e("shellcheck", script)

      expect(status).to be_success, out
    end

    it "names the stack, cluster and database from the branch, with no AWS call", :aggregate_failures do
      out, _err, status = run("name", env: { "BRANCH" => "feature-x" })

      expect(status).to be_success
      expect(out).to include("env:      feature-x", "stack:    hecks-widgets-preview-feature-x", "database: widgets_pv_feature_x")
    end

    def env_of(branch)
      out, = run("name", env: { "BRANCH" => branch })
      out[/^env:\s+(\S+)/, 1]
    end

    it "sanitizes odd branch names and keeps look-alikes apart with a hash", :aggregate_failures do
      expect(env_of("feat/Login_Page")).to match(/\Afeat-login-pag-[0-9a-f]{5}\z/)
      expect(env_of("feat-login-page")).to eq("feat-login-page")
      expect(env_of("feat/x")).not_to eq(env_of("feat-x"))
      expect(env_of("feat_x")).not_to eq(env_of("feat-x"))
    end

    it "truncates a long branch name to what an ALB name allows, still distinct", :aggregate_failures do
      first = run("name", env: { "BRANCH" => "a-very-long-branch-name-alpha" })[0][/^env:\s+(\S+)/, 1]
      second = run("name", env: { "BRANCH" => "a-very-long-branch-name-beta" })[0][/^env:\s+(\S+)/, 1]

      expect(first).to match(/\A[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?\z/)
      expect([first.length, second.length]).to all(be <= 20)
      expect(first).not_to eq(second)
    end

    def derived_names(branch)
      out, _err, status = run("name", env: { "BRANCH" => branch })
      [out[/^env:\s+(\S+)/, 1], out[/^database:\s+(\S+)/, 1]] if status.success?
    end

    it "keeps every derived name inside the template's own patterns", :aggregate_failures do
      env = Regexp.new(template(multi)["Parameters"]["EnvName"]["AllowedPattern"])
      db = Regexp.new(template(multi)["Parameters"]["DbName"]["AllowedPattern"])
      names = ["feat/Ünïcode", "UPPER_case-Branch", "a." * 30, "release/2026.09"].filter_map { |b| derived_names(b) }

      expect(names.map(&:first)).to all(match(env))
      expect(names.map(&:last)).to all(match(db))
    end

    def refusal_of(branch)
      _out, err, status = run("name", env: { "BRANCH" => branch })
      [err, status]
    end

    it "refuses the protected branches", :aggregate_failures do
      %w[main master].each do |branch|
        err, status = refusal_of(branch)

        expect(status).not_to be_success
        expect(err).to match(/refusing to make a preview of #{branch}/)
      end
    end

    it "refuses a detached HEAD", :aggregate_failures do
      err, status = refusal_of("HEAD")

      expect(status).not_to be_success
      expect(err).to include("detached HEAD")
    end

    it "refuses a branch with no usable characters", :aggregate_failures do
      _out, err, status = run("name", env: { "BRANCH" => "///" })

      expect(status).not_to be_success
      expect(err).to include("no usable characters")
    end

    it "prints usage for an unknown command", :aggregate_failures do
      _out, err, status = run("frobnicate")

      expect(status).not_to be_success
      expect(err).to match(/usage: preview.sh <deploy\|destroy\|ensure-database\|list\|url\|name\|login>/)
    end

    it "offers the same commands as the header documents" do
      header = File.read(script)[/\A(?:#.*\n)+/]
      documented = header.scan(/^#   preview\.sh (\S+)/).flatten

      expect(documented).to match_array(%w[deploy destroy list url name ensure-database login])
    end

    it "bakes the stack contract: owner outputs, prefix, image tags and local images", :aggregate_failures do
      expect(text).to include('PREFIX="hecks-widgets-preview"', 'DATABASE_ENDPOINT_OUTPUT="DatabaseEndpoint"',
                              'SERVICES="site admin core"')
      expect(text).to include('site) echo "SiteImageTag"', 'core) echo "CoreImageTag"', 'core) echo "core:latest"')
      expect(text).to include(*%w[VpcId PrivateSubnetAId PrivateSubnetBId PublicSubnetId BastionSubnetId FunctionSecurityGroupId])
    end

    it "only operates on stacks it named", :aggregate_failures do
      expect(text).to include('"$PREFIX"-*) ;;')
      expect(text).to match(/cmd_destroy\(\) \{\n  guard_stack_name/)
    end

    it "mints a signup token the host would verify", :aggregate_failures do
      encoded, signature = minted_token("signup", "s3cret")
      payload = JSON.parse(Base64.urlsafe_decode64(encoded))

      expect(payload["purpose"]).to eq("signup")
      expect(payload["exp"]).to be > Time.now.to_i
      expect(signature).to eq(OpenSSL::HMAC.hexdigest("SHA256", "signup:s3cret", encoded))
    end

    it "mints a session token keyed with the bare secret and carrying the email", :aggregate_failures do
      encoded, signature = minted_token("session", "s3cret", "me@example.test")

      expect(JSON.parse(Base64.urlsafe_decode64(encoded))["email"]).to eq("me@example.test")
      expect(signature).to eq(OpenSSL::HMAC.hexdigest("SHA256", "s3cret", encoded))
    end

    it "uses the configured session cookie in the login instructions", :aggregate_failures do
      custom = generate({ session_cookie: "wid_session", landing_path: "/start" }.merge(containers: multi[:containers]))
      text = custom.fetch("preview.sh")

      expect(text).to include('SESSION_COOKIE="wid_session"', 'LANDING_PATH="/start"')
      expect(File.read(script)).to include('SESSION_COOKIE="hecks_session"')
    end

    it "drops the signup and login commands when first_admin is false", :aggregate_failures do
      quiet = generate({ first_admin: false, containers: multi[:containers] }).fetch("preview.sh")
      File.write(script, quiet)
      expect_valid_bash
      expect(quiet).not_to include("signup_admin", "cmd_login", "mint_token")
      expect(template(first_admin: false, containers: multi[:containers])["Resources"]).not_to have_key("ListenerRuleCore1")
    end
  end

  describe "through hecks deploy project", :io do
    let(:out_dir) { Dir.mktmpdir("preview-out") }
    let(:work_dir) { Dir.mktmpdir("preview-src") }

    def root = File.expand_path("..", __dir__)

    def basename = "project_deploy_preview_spec_fixture"

    def plain_world
      <<~WORLD
        Hecks.world "Scratch" do
          deployed_to("AwsFargate") do
            region "us-east-1"
            cpu 256
            memory 512
            port 8080
          end
        end
      WORLD
    end

    def preview_world
      <<~WORLD
        Hecks.world "Scratch" do
          deployed_to("AwsFargate") do
            region "us-east-1"
            cpu 256
            memory 512
            port 8080
            preview do
              containers [{ name: "core", port: 8080, host: true, default: true }]
              session_cookie "scratch_session"
            end
          end
        end
      WORLD
    end

    PREVIEW_SPEC_BLUEBOOK = <<~BLUEBOOK.freeze
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
    BLUEBOOK

    def write_project(world_body)
      bluebook_dir = File.join(work_dir, basename, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{basename}.bluebook"), PREVIEW_SPEC_BLUEBOOK)
      File.write(File.join(bluebook_dir, "#{basename}.world"), world_body)
      File.join(work_dir, basename)
    end

    def generate_with(world_body)
      FileUtils.rm_rf(Dir.glob(File.join(out_dir, "*")))
      _out, err, status = ProjectDeployRunner.run(write_project(world_body), "--out=#{out_dir}", root: root)
      raise "hecks deploy project failed: #{err}" unless status.success?

      Dir.children(out_dir).to_h { |name| [name, File.read(File.join(out_dir, name))] }
    end

    after { FileUtils.rm_rf([out_dir, work_dir]) }

    it "adds no file unless the preview block is present" do
      expect(generate_with(plain_world).keys).to match_array(%w[template.yaml bastion.yaml Dockerfile Makefile])
    end

    it "leaves every existing output byte-identical when the preview block is present", :aggregate_failures do
      plain = generate_with(plain_world)
      previewed = generate_with(preview_world)

      expect(previewed.keys).to match_array(plain.keys + %w[preview.yaml preview.sh])
      plain.each { |name, text| expect(previewed[name]).to eq(text), "#{name} changed" }
    end

    it "generates a preview from the nested block, with the domain's own facts", :aggregate_failures do
      files = generate_with(preview_world)
      env = by_name(host_environment(parsed(files["preview.yaml"])))

      expect(env).to include("HECKS_DOMAIN" => "Scratch", "HECKS_SESSION_COOKIE" => "scratch_session")
      expect(files["preview.sh"]).to include(%(PREFIX="hecks-#{basename.tr("_", "-")}-preview"))
    end

    it "generates a single-container preview from a bare preview setting" do
      bare = plain_world.sub("port 8080\n", "port 8080\n    preview true\n")
      containers = containers_of(parsed(generate_with(bare)["preview.yaml"]))

      expect(containers.map { |c| c["Name"] }).to eq([basename.tr("_", "-")[0, 30].sub(/-+\z/, "")])
    end

    it "refuses an unknown preview key through the CLI" do
      broken = plain_world.sub("port 8080\n", "port 8080\n    preview do\n      colour \"red\"\n    end\n")

      expect { generate_with(broken) }.to raise_error(/unknown preview setting/)
    end
  end
end
