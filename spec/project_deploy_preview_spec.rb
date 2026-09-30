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

  def template(preview, extra = {})
    YAML.safe_load(generate(preview, extra).fetch("preview.yaml"), permitted_classes: [], aliases: true)
  end

  def resources_of(doc, type)
    doc["Resources"].select { |_name, resource| resource["Type"] == type }
  end

  describe "opting in" do
    it "generates nothing without a preview setting" do
      expect(described_class.call(deploy_settings: {}, main: main)).to eq({})
      expect(described_class.call(deploy_settings: { preview: false }, main: main)).to eq({})
    end

    it "accepts `true` and an empty block as all defaults" do
      expect(generate(true).keys).to eq(%w[preview.yaml preview.sh])
      expect(generate({}).keys).to eq(%w[preview.yaml preview.sh])
    end
  end

  describe "the world's nested settings block" do
    def declared(&block)
      world = Hecks::Bluebook::DSL::WorldBuilder.build("Scratch") { deployed_to("AwsFargate", &block) }
      world.for_verb("deployed_to")
    end

    it "records a block as a nested Hash and a plain call as its argument" do
      settings = declared do
        region "us-east-1"
        preview do
          cpu 512
          containers [{ name: "web", port: 8080 }]
        end
      end

      expect(settings[:region]).to eq("us-east-1")
      expect(settings[:preview]).to eq(cpu: 512, containers: [{ name: "web", port: 8080 }])
    end

    it "records an empty block as an empty Hash, which still opts in" do
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
      expect(s.protected_databases).to include("widgets", "postgres")
      expect([s.cpu, s.memory, s.log_retention_days]).to eq([256, 512, 7])
    end

    it "borrows a Shared main stack's owner" do
      shared = Hecks::Projections::Deploy::Preview::Settings.build(
        {}, deploy_settings: {}, main: main.merge(owner_stack: "hecks-owner", db_name: "owner")
      )

      expect(shared.owner_stack).to eq("hecks-owner")
      expect(shared.protected_databases).to include("owner")
    end

    it "lets every key be overridden" do
      s = settings(prefix: "wid-pv", database_stack: "aurora-stack", database_endpoint_output: "ClusterEndpoint",
                   database_secret_output: "SecretArn", cpu: 512, memory: 1024, session_cookie: "wid_session",
                   protected_databases: ["keepme"], first_admin: false)

      expect(s.prefix).to eq("wid-pv")
      expect([s.database_stack, s.database_endpoint_output, s.database_secret_output]).to eq(
        %w[aurora-stack ClusterEndpoint SecretArn]
      )
      expect([s.cpu, s.memory, s.session_cookie, s.first_admin]).to eq([512, 1024, "wid_session", false])
      expect(s.protected_databases).to include("keepme")
    end

    it "refuses an unknown key, naming the known ones" do
      expect { settings(colour: "red") }.to raise_error(ArgumentError, /unknown preview setting.*colour.*known: prefix/)
    end

    it "refuses values that would break a name, a database or the script" do
      expect { settings(prefix: "Bad Prefix") }.to raise_error(ArgumentError, /prefix/)
      expect { settings(db_prefix: "x; drop") }.to raise_error(ArgumentError, /db_prefix/)
      expect { settings(alb_prefix: "waytoolongforalb") }.to raise_error(ArgumentError, /alb_prefix/)
      expect { settings(log_retention_days: 8) }.to raise_error(ArgumentError, /log_retention_days/)
      expect { settings(protected_branches: ["a b"]) }.to raise_error(ArgumentError, /protected_branches/)
      expect { settings(signup_path: "signups") }.to raise_error(ArgumentError, /signup_path/)
    end

    it "refuses a container list that cannot be one task" do
      bad = lambda do |containers|
        expect { settings(containers: containers) }.to raise_error(ArgumentError)
      end

      bad.call([])
      bad.call([{ name: "a", port: 1 }, { name: "a", port: 2 }])
      bad.call([{ name: "a", port: 1 }, { name: "b", port: 1 }])
      bad.call([{ name: "a", port: 1, default: true }, { name: "b", port: 2, default: true }])
      bad.call([{ name: "a", port: 1, host: true }, { name: "b", port: 2, host: true }])
      bad.call([{ name: "Bad Name", port: 1 }])
      bad.call([{ name: "a" }])
      bad.call([{ name: "a", port: 1, image: "x y" }])
      bad.call([{ name: "a", port: 1, secrets: ["lowercase"] }])
    end

    it "reads a container list from the shared setting when the preview block gives none" do
      shared = { containers: [{ name: "only", port: 9000, host: true }] }
      s = settings({}, shared)

      expect(s.containers.map(&:name)).to eq(["only"])
      expect(s.default_container.name).to eq("only")
    end
  end

  describe "preview.yaml for one container" do
    let(:doc) { template({}) }

    it "parses and declares the parameters preview.sh passes" do
      expect(doc["Parameters"].keys).to include(
        "EnvName", "DbName", "OwningVpcId", "OwningSubnetAId", "OwningSubnetBId", "OwningPublicSubnetAId",
        "OwningPublicSubnetBId", "OwningSecurityGroupId", "OwningDatabaseEndpoint", "OwningDatabaseSecretArn",
        "WidgetsImageTag", "DesiredCount"
      )
      expect(doc["Parameters"]["DesiredCount"]["Default"]).to eq(0)
    end

    it "constrains EnvName and DbName by pattern" do
      env = Regexp.new(doc["Parameters"]["EnvName"]["AllowedPattern"])
      db = Regexp.new(doc["Parameters"]["DbName"]["AllowedPattern"])

      accepted = ->(pattern, values) { values.grep(pattern) }

      expect(accepted.call(env, ["feat-x", "a1", "a", "-x", "x-", "Upper", "a" * 21])).to eq(%w[feat-x a1 a])
      expect(accepted.call(db, ["widgets_pv_x", "1abc", "a-b", "a;b"])).to eq(%w[widgets_pv_x])
    end

    it "owns one repository, one target group, one service and one distribution per branch" do
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

    it "makes a per-branch secret and points the host at it" do
      expect(resources_of(doc, "AWS::SecretsManager::Secret").keys).to eq(["SessionSecret"])
      env = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"].first["Environment"]
      by_name = env.to_h { |e| [e["Name"], e["Value"]] }

      expect(by_name).to include(
        "HECKS_DOMAIN" => "Widgets", "HECKS_SERVE_MODE" => "1", "PORT" => "8080", "DB_NAME" => "DbName",
        "SESSION_SECRET_ARN" => "SessionSecret", "DB_HOST" => "OwningDatabaseEndpoint",
        "DB_SECRET_ARN" => "OwningDatabaseSecretArn", "HECKS_WASM_PATH" => "/usr/local/bin/widgets.wasm"
      )
      expect(by_name).not_to have_key("HECKS_SCHEMA")
      expect(env.map { |e| e["Name"] }.uniq.size).to eq(env.size)
    end

    it "sets the schema and the session cookie when configured" do
      configured = YAML.safe_load(
        described_class.call(deploy_settings: { preview: { session_cookie: "wid_session" } },
                             main:            main.merge(schema: "widgets_schema")).fetch("preview.yaml")
      )
      env = configured["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"].first["Environment"]
      by_name = env.to_h { |e| [e["Name"], e["Value"]] }

      expect(by_name).to include("HECKS_SCHEMA" => "widgets_schema", "HECKS_SESSION_COOKIE" => "wid_session")
    end

    it "keeps the ALB reachable only from CloudFront and the shared group only from the ALB" do
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

    it "sizes the task from the main stack and lets the preview override it" do
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

    it "runs a Postgres client image with the credentials as container secrets, never as plain values" do
      expect(task["Image"]).to eq("public.ecr.aws/docker/library/postgres:16-alpine")
      expect(task["Secrets"].map { |s| s["Name"] }).to eq(%w[PGUSER PGPASSWORD])
      expect(task["Environment"].map { |e| e["Name"] }).not_to include("PGPASSWORD")
    end

    it "refuses the main database and the maintenance databases" do
      protected = task["Environment"].find { |e| e["Name"] == "PROTECTED_DATABASES" }["Value"].split

      expect(protected).to include("widgets", "postgres", "template0", "template1")
    end

    it "runs a script that validates the name, creates idempotently, and can drop" do
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

    it "gives each container its own repository, image-tag parameter and log prefix" do
      expect(resources_of(doc, "AWS::ECR::Repository").keys).to eq(%w[SiteRepository AdminRepository CoreRepository])
      expect(doc["Parameters"].keys).to include("SiteImageTag", "AdminImageTag", "CoreImageTag")
      containers = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"]

      expect(containers.map { |c| c["Name"] }).to eq(%w[site admin core])
      expect(containers.map { |c| c["LogConfiguration"]["Options"]["awslogs-stream-prefix"] }).to eq(%w[site admin core])
    end

    it "sends unmatched requests to the default container and paths to the others" do
      listener = doc["Resources"]["Listener"]["Properties"]
      rules = resources_of(doc, "AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(listener["DefaultActions"].first["TargetGroupArn"]).to eq("CoreTargetGroup")
      expect(rules.map { |r| r["Conditions"].first["Values"] }).to eq([["/app/*"], ["/admin/*"]])
      expect(rules.map { |r| r["Priority"] }).to eq([10, 20])
    end

    it "registers every routed container with the service and the shared security group" do
      balancers = doc["Resources"]["Service"]["Properties"]["LoadBalancers"]

      expect(balancers.map { |b| b["ContainerName"] }).to eq(%w[site admin core])
      expect(resources_of(doc, "AWS::EC2::SecurityGroupIngress").size).to eq(3)
      expect(doc["Resources"]["Service"]["DependsOn"]).to include("Listener", "ListenerRuleSite1", "ListenerRuleAdmin1")
    end

    it "gives the host the domain environment and only the database containers the database environment" do
      env = lambda do |name|
        containers = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"]
        containers.find { |c| c["Name"] == name }["Environment"].to_h { |e| [e["Name"], e["Value"]] }
      end

      expect(env.call("core")).to include("HECKS_DOMAIN", "DB_NAME")
      expect(env.call("admin")).to include("DB_NAME")
      expect(env.call("admin")).not_to include("HECKS_DOMAIN")
      expect(env.call("site")).not_to include("DB_NAME")
    end

    it "routes the signup path to a host that is not the default" do
      other = template(containers: [{ name: "site", port: 8080, default: true },
                                    { name: "core", port: 8082, host: true }])
      rules = resources_of(other, "AWS::ElasticLoadBalancingV2::ListenerRule").values

      expect(rules.map { |r| r["Properties"]["Conditions"].first["Values"] }).to eq([["/signups"]])
    end

    it "generates a secret per declared name and lets the task role read it" do
      secrets = resources_of(doc, "AWS::SecretsManager::Secret").keys
      role = doc["Resources"]["TaskRole"]["Properties"]["Policies"].find { |p| p["PolicyName"] == "PreviewSecretRead" }
      env = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"][1]["Environment"]

      expect(secrets).to eq(%w[SessionSecret AdminSigningKeySecret])
      expect(role["PolicyDocument"]["Statement"].first["Resource"]).to eq(%w[SessionSecret AdminSigningKeySecret])
      expect(env.find { |e| e["Name"] == "SIGNING_KEY_ARN" }["Value"]).to eq("AdminSigningKeySecret")
    end

    it "renders the preview URL token as an intrinsic against the distribution" do
      raw = generate(multi).fetch("preview.yaml")

      expect(raw).to include('Value: !Sub "https://${PreviewDistribution.DomainName}"')
    end

    it "splits more than five paths across rules with distinct priorities" do
      many = template(containers: [{ name: "a", port: 1, default: true },
                                   { name: "b", port: 2, paths: (1..7).map { |i| "/p#{i}/*" } }])
      rules = resources_of(many, "AWS::ElasticLoadBalancingV2::ListenerRule").values.map { |r| r["Properties"] }

      expect(rules.map { |r| r["Conditions"].first["Values"].size }).to eq([5, 2])
      expect(rules.map { |r| r["Priority"] }.uniq.size).to eq(2)
    end

    it "gives a container with no route no target group and no port mapping" do
      sidecar = template(containers: [{ name: "a", port: 1, default: true }, { name: "worker", port: 2 }])
      definition = sidecar["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"].last

      expect(resources_of(sidecar, "AWS::ElasticLoadBalancingV2::TargetGroup").keys).to eq(["ATargetGroup"])
      expect(definition).not_to have_key("PortMappings")
    end
  end

  describe "preview.sh", :io do
    let(:dir) { Dir.mktmpdir("preview-script") }
    let(:script) { File.join(dir, "preview.sh") }

    before { File.write(script, generate(multi).fetch("preview.sh")) }
    after { FileUtils.rm_rf(dir) }

    def run(*args, env: {})
      Open3.capture3(env, "bash", script, *args)
    end

    it "is valid bash" do
      out, status = Open3.capture2e("bash", "-n", script)

      expect(status).to be_success, out
    end

    it "passes shellcheck when it is installed" do
      skip "shellcheck is not installed" unless system("command -v shellcheck >/dev/null 2>&1")

      out, status = Open3.capture2e("shellcheck", script)

      expect(status).to be_success, out
    end

    it "names the stack, cluster and database from the branch, with no AWS call" do
      out, _err, status = run("name", env: { "BRANCH" => "feature-x" })

      expect(status).to be_success
      expect(out).to include("env:      feature-x", "stack:    hecks-widgets-preview-feature-x", "database: widgets_pv_feature_x")
    end

    it "sanitizes odd branch names and keeps look-alikes apart with a hash" do
      env_of = lambda do |branch|
        out, = run("name", env: { "BRANCH" => branch })
        out[/^env:\s+(\S+)/, 1]
      end
      slash = env_of.call("feat/Login_Page")
      dash = env_of.call("feat-login-page")

      expect(slash).to match(/\Afeat-login-pag-[0-9a-f]{5}\z/)
      expect(dash).to eq("feat-login-page")
      expect(env_of.call("feat/x")).not_to eq(env_of.call("feat-x"))
      expect(env_of.call("feat_x")).not_to eq(env_of.call("feat-x"))
    end

    it "truncates a long branch name to what an ALB name allows, still distinct" do
      first = run("name", env: { "BRANCH" => "a-very-long-branch-name-alpha" })[0][/^env:\s+(\S+)/, 1]
      second = run("name", env: { "BRANCH" => "a-very-long-branch-name-beta" })[0][/^env:\s+(\S+)/, 1]

      expect(first).to match(/\A[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?\z/)
      expect([first.length, second.length]).to all(be <= 20)
      expect(first).not_to eq(second)
    end

    it "keeps every derived name inside the template's own patterns" do
      env = Regexp.new(template(multi)["Parameters"]["EnvName"]["AllowedPattern"])
      db = Regexp.new(template(multi)["Parameters"]["DbName"]["AllowedPattern"])

      ["feat/Ünïcode", "UPPER_case-Branch", "a." * 30, "release/2026.09"].each do |branch|
        out, _err, status = run("name", env: { "BRANCH" => branch })
        next unless status.success?

        expect(out[/^env:\s+(\S+)/, 1]).to match(env)
        expect(out[/^database:\s+(\S+)/, 1]).to match(db)
      end
    end

    it "refuses the protected branches and a detached HEAD" do
      %w[main master].each do |branch|
        _out, err, status = run("name", env: { "BRANCH" => branch })

        expect(status).not_to be_success
        expect(err).to match(/refusing to make a preview of #{branch}/)
      end
      _out, err, status = run("name", env: { "BRANCH" => "HEAD" })

      expect(status).not_to be_success
      expect(err).to include("detached HEAD")
    end

    it "refuses a branch with no usable characters" do
      _out, err, status = run("name", env: { "BRANCH" => "///" })

      expect(status).not_to be_success
      expect(err).to include("no usable characters")
    end

    it "prints usage for an unknown command" do
      _out, err, status = run("frobnicate")

      expect(status).not_to be_success
      expect(err).to match(/usage: preview.sh <deploy\|destroy\|ensure-database\|list\|url\|name\|login>/)
    end

    it "offers the same commands as the header documents" do
      header = File.read(script)[/\A(?:#.*\n)+/]
      documented = header.scan(/^#   preview\.sh (\S+)/).flatten

      expect(documented).to match_array(%w[deploy destroy list url name ensure-database login])
    end

    it "bakes the stack contract: owner outputs, prefix, image tags and local images" do
      text = File.read(script)

      expect(text).to include('PREFIX="hecks-widgets-preview"', 'DATABASE_ENDPOINT_OUTPUT="DatabaseEndpoint"',
                              'SERVICES="site admin core"')
      expect(text).to include('site) echo "SiteImageTag"', 'core) echo "CoreImageTag"', 'core) echo "core:latest"')
      %w[VpcId PrivateSubnetAId PrivateSubnetBId PublicSubnetId BastionSubnetId FunctionSecurityGroupId].each do |key|
        expect(text).to include(key)
      end
    end

    it "only operates on stacks it named" do
      text = File.read(script)

      expect(text).to include('"$PREFIX"-*) ;;')
      expect(text).to match(/cmd_destroy\(\) \{\n  guard_stack_name/)
    end

    it "mints a signup token the host would verify" do
      out, err, status = Open3.capture3("bash", "-c", "source #{script}; mint_token signup s3cret")
      expect(status).to be_success, err
      encoded, signature = out.strip.split(".")
      payload = JSON.parse(Base64.urlsafe_decode64(encoded))

      expect(payload["purpose"]).to eq("signup")
      expect(payload["exp"]).to be > Time.now.to_i
      expect(signature).to eq(OpenSSL::HMAC.hexdigest("SHA256", "signup:s3cret", encoded))
    end

    it "mints a session token keyed with the bare secret and carrying the email" do
      out, err, status = Open3.capture3("bash", "-c", "source #{script}; mint_token session s3cret me@example.test")
      expect(status).to be_success, err
      encoded, signature = out.strip.split(".")

      expect(JSON.parse(Base64.urlsafe_decode64(encoded))["email"]).to eq("me@example.test")
      expect(signature).to eq(OpenSSL::HMAC.hexdigest("SHA256", "s3cret", encoded))
    end

    it "uses the configured session cookie in the login instructions" do
      custom = generate({ session_cookie: "wid_session", landing_path: "/start" }.merge(containers: multi[:containers]))
      text = custom.fetch("preview.sh")

      expect(text).to include('SESSION_COOKIE="wid_session"', 'LANDING_PATH="/start"')
      expect(File.read(script)).to include('SESSION_COOKIE="hecks_session"')
    end

    it "drops the signup and login commands when first_admin is false" do
      quiet = generate({ first_admin: false, containers: multi[:containers] }).fetch("preview.sh")
      File.write(script, quiet)
      out, status = Open3.capture2e("bash", "-n", script)

      expect(status).to be_success, out
      expect(quiet).not_to include("signup_admin", "cmd_login", "mint_token")
      expect(template(first_admin: false, containers: multi[:containers])["Resources"]).not_to have_key("ListenerRuleCore1")
    end
  end

  describe "through hecks deploy project", :io do
    let(:root) { File.expand_path("..", __dir__) }
    let(:basename) { "project_deploy_preview_spec_fixture" }
    let(:out_dir) { Dir.mktmpdir("preview-out") }
    let(:work_dir) { Dir.mktmpdir("preview-src") }
    let(:plain_world) do
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
    let(:preview_world) do
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

    def generate_with(world_body)
      FileUtils.rm_rf(Dir.glob(File.join(out_dir, "*")))
      bluebook_dir = File.join(work_dir, basename, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{basename}.bluebook"), PREVIEW_SPEC_BLUEBOOK)
      File.write(File.join(bluebook_dir, "#{basename}.world"), world_body)
      _out, err, status = ProjectDeployRunner.run(File.join(work_dir, basename), "--out=#{out_dir}", root: root)
      raise "hecks deploy project failed: #{err}" unless status.success?

      Dir.children(out_dir).to_h { |name| [name, File.read(File.join(out_dir, name))] }
    end

    after { FileUtils.rm_rf([out_dir, work_dir]) }

    it "adds no file unless the preview block is present" do
      expect(generate_with(plain_world).keys).to match_array(%w[template.yaml bastion.yaml Dockerfile Makefile])
    end

    it "leaves every existing output byte-identical when the preview block is present" do
      plain = generate_with(plain_world)
      previewed = generate_with(preview_world)

      expect(previewed.keys).to match_array(plain.keys + %w[preview.yaml preview.sh])
      plain.each { |name, text| expect(previewed[name]).to eq(text), "#{name} changed" }
    end

    it "generates a preview from the nested block, with the domain's own facts" do
      files = generate_with(preview_world)
      doc = YAML.safe_load(files["preview.yaml"], permitted_classes: [], aliases: true)
      env = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"].first["Environment"]
      by_name = env.to_h { |e| [e["Name"], e["Value"]] }

      expect(by_name).to include("HECKS_DOMAIN" => "Scratch", "HECKS_SESSION_COOKIE" => "scratch_session")
      expect(files["preview.sh"]).to include(%(PREFIX="hecks-#{basename.tr('_', '-')}-preview"))
    end

    it "generates a single-container preview from a bare preview setting" do
      bare = plain_world.sub("port 8080\n", "port 8080\n    preview true\n")
      doc = YAML.safe_load(generate_with(bare)["preview.yaml"], permitted_classes: [], aliases: true)
      containers = doc["Resources"]["TaskDefinition"]["Properties"]["ContainerDefinitions"]

      expect(containers.map { |c| c["Name"] }).to eq([basename.tr("_", "-")[0, 30].sub(/-+\z/, "")])
    end

    it "refuses an unknown preview key through the CLI" do
      broken = plain_world.sub("port 8080\n", "port 8080\n    preview do\n      colour \"red\"\n    end\n")

      expect { generate_with(broken) }.to raise_error(/unknown preview setting/)
    end
  end
end
