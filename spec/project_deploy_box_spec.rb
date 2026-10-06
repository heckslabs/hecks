require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/projections/deploy/template_diff"

# `hecks deploy project` for a domain that declares `deployed_to("AwsBox")`: one EC2 box that runs the
# domain's containers behind Caddy, and a plain RDS instance. Two promises: a world that sets only a
# container renders the minimal golden stack, and a fully-specified world renders the full one.
#
# The golden files in `spec/fixtures/deploy_box_golden/<world>/` are generator output. To regenerate
# after a deliberate change, write the world below into `<dir>/bluebook/scratch_fixture.world` beside
# `scratch_fixture.bluebook`, run `hecks deploy project <dir> --out=spec/fixtures/deploy_box_golden/<world>`
# and review the diff; never edit a golden file by hand.
RSpec.describe "hecks deploy project — a deployed_to(\"AwsBox\") stack", :io do
  BOX_ROOT_DIR = File.expand_path("..", __dir__)
  BOX_GOLDEN_DIR = File.join(__dir__, "fixtures", "deploy_box_golden")
  BOX_FIXTURE_NAME = "scratch_fixture".freeze

  module BoxGeneratedWorlds
    def self.fetch(key) = (@worlds ||= {})[key] ||= yield
  end

  BOX_BLUEBOOK = <<~BOX_BLUEBOOK.freeze
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
  BOX_BLUEBOOK

  BOX_WORLDS = {
    "default"          => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          containers [{ name: "web", port: 8080 }]
        end
      end
    WORLD
    "tunnel"           => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          containers [{ name: "web", port: 8080 }, { name: "stats", port: 3000 }]
          default_container "web"
          tunnel({ to: "stats", token_secret: "scratch/tunnel-token" })
        end
      end
    WORLD
    "taskdef"          => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          stack_name "widget-shop"
          task_definition "widget-platform"
          containers [{ name: "website", port: 8080 }, { name: "cms", port: 8081 }]
          default_container "website"
          routes [{ container: "cms", paths: ["/cms/*"] }]
          origin_header "X-Origin-Secret"
          origin_secret "widget/origin-secret"
          origin_env ["WIDGET_ORIGIN"]
        end
      end
    WORLD
    "migration"        => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          stack_name "widget-shop"
          database_name "widgetdb"
          containers [{ name: "web", port: 8080 }]
          migration({ schemas: ["widgets", "widgets_cms"], source_database: "legacy" })
        end
      end
    WORLD
    "hosting_taskdef"  => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          stack_name "widget-shop"
          task_definition "widget-platform"
          containers [{ name: "website", port: 8080 }, { name: "cms", port: 8081 },
                      { name: "domain", port: 8082, tag_parameter: "EngineImageTag" }]
          default_container "website"
          routes [{ container: "cms", paths: ["/cms/*"] }]
          origin_header "X-Origin-Secret"
          origin_secret "widget/origin-secret"
          origin_env ["WIDGET_ORIGIN"]
          hosting_scripts true
          hosting_stack "widget-platform"
          smoke_repo "acme/widget-shop"
          smoke_workflow "smoke-prod.yml"
          expected_eras ["a1b2c3"]
          public_url "https://widgets.example.com"
        end
      end
    WORLD
    "hosting_services" => <<~WORLD,
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "us-east-1"
          stack_name "widget-shop"
          containers [{ name: "website", port: 8080 }, { name: "cms", port: 8081, repository: "acme-cms" }]
          default_container "website"
          routes [{ container: "cms", paths: ["/cms/*"] }]
          hosting_scripts true
          smoke_workflow "smoke-prod.yml"
        end
      end
    WORLD
    "full"             => <<~WORLD
      Hecks.world "Scratch" do
        deployed_to("AwsBox") do
          region "eu-west-1"
          stack_prefix "acme"
          stack_name "widget-shop"
          instance_type "t4g.large"
          volume_gb 50
          swap_gb 4
          database_class "db.t4g.medium"
          storage_gb 50
          backup_days 14
          snapshots_keep 14
          containers [
            { name: "website", port: 8080, repository: "acme-platform-website", env: { "HOST" => "0.0.0.0" },
              secrets: { "AUTH_SECRET" => "acme/session-secret" } },
            { name: "cms", port: 8081 },
            { name: "domain", port: 8082, env: { "HECKS_SCHEMA" => "widgets" } }
          ]
          default_container "website"
          routes [
            { container: "cms", paths: ["/cms/*"] },
            { container: "domain", paths: ["/registrations", "/registrations/*", "/webhooks/*"] }
          ]
          origin_header "X-Origin-Secret"
          origin_secret "acme/origin-secret"
          secret_prefixes ["acme/*"]
          writable_secrets ["acme/payments-account"]
          tunnel true
          s3_access [{ bucket: "acme-media", write: true }, { bucket: "acme-assets" }]
        end
      end
    WORLD
  }.freeze

  def generate(world_body)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, BOX_FIXTURE_NAME)
      bluebook_dir = File.join(domain, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{BOX_FIXTURE_NAME}.bluebook"), BOX_BLUEBOOK)
      File.write(File.join(bluebook_dir, "#{BOX_FIXTURE_NAME}.world"), world_body)
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: BOX_ROOT_DIR)
      return [nil, stderr] unless status.success?

      files = Dir.children(out).to_h do |name|
        [name, File.read(File.join(out, name)).gsub(domain, "<domain>").gsub(BOX_ROOT_DIR, "<root>")]
      end
      [files, stderr]
    end
  end

  def cached(key, world_body) = BoxGeneratedWorlds.fetch(key) { generate(world_body) }

  def template_of(text) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(text)

  def syntax_ok?(script)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "script.sh")
      File.write(path, script)
      _out, err, status = Open3.capture3("bash", "-n", path)
      [status.success?, err]
    end
  end

  BOX_WORLDS.each_key do |name|
    describe "the #{name} world" do
      let(:generated) { cached(name, BOX_WORLDS.fetch(name)) }
      let(:files) { generated.first }

      it "renders its golden files" do
        expect(files).not_to be_nil, generated.last

        golden_names = Dir.children(File.join(BOX_GOLDEN_DIR, name)).sort
        expect(files.keys).to match_array(golden_names)
        golden_names.each do |file|
          golden = File.read(File.join(BOX_GOLDEN_DIR, name, file))
          expect(files[file]).to eq(golden), "#{name}/#{file} differs from its golden file"
        end
      end

      it "renders two templates that load as CloudFormation and scripts that parse" do
        expect(files).not_to be_nil, generated.last

        expect { template_of(files["rds.yaml"]) }.not_to raise_error
        expect { template_of(files["box.yaml"]) }.not_to raise_error
        files.keys.grep(/\.sh\z/).each do |script|
          ok, err = syntax_ok?(files[script])
          expect(ok).to be(true), "#{script}: #{err}"
        end
      end
    end
  end

  describe "the default world" do
    let(:files) { cached("default", BOX_WORLDS.fetch("default")).first }

    it "holds and retries a request while a container restarts, and restarts the proxy when its config changed" do
      caddy = files["Caddyfile"]
      expect(caddy.scan("reverse_proxy").size).to be >= 1
      expect(caddy.scan("lb_try_duration 15s").size).to eq(caddy.scan("reverse_proxy").size)
      expect(caddy.scan("lb_try_interval 250ms").size).to eq(caddy.scan("reverse_proxy").size)
      expect(files["deploy-box.sh"]).to include("CADDY_BEFORE=", "restart caddy")
    end

    it "writes its shell scripts executable, and waits for the containers instead of sleeping" do
      Dir.mktmpdir do |dir|
        domain = File.join(dir, BOX_FIXTURE_NAME)
        FileUtils.mkdir_p(File.join(domain, "bluebook"))
        File.write(File.join(domain, "bluebook", "#{BOX_FIXTURE_NAME}.bluebook"), BOX_BLUEBOOK)
        File.write(File.join(domain, "bluebook", "#{BOX_FIXTURE_NAME}.world"), BOX_WORLDS.fetch("default"))
        out = File.join(dir, "out")
        _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: BOX_ROOT_DIR)
        expect(status.success?).to be(true), stderr

        scripts = Dir.children(out).select { |name| name.end_with?(".sh") }
        expect(scripts).to include("deploy-box.sh", "render-compose.sh", "fetch-secrets.sh")
        expect(scripts.reject { |name| File.executable?(File.join(out, name)) }).to eq([])
      end
      expect(files["deploy-box.sh"]).not_to include("sleep 20")
      expect(files["deploy-box.sh"]).to include("Up (Less than a second|[0-4] seconds?)")
    end

    it "can mount extra proxy sites, a smoke listener and admit a bastion" do
      expect(files["Caddyfile"]).to include("auto_https disable_redirects", "import /etc/caddy/extra/*")
      expect(files["render-compose.sh"]).to include("./caddy-extra:/etc/caddy/extra:ro")
      expect(files["deploy-box.sh"]).to include("SMOKE_LISTENER", "caddy-extra/smoke.caddy")
      box = template_of(files["box.yaml"])
      expect(box["Resources"]["BoxRole"]["Properties"]["Policies"].map { |p| p.is_a?(Hash) ? p["PolicyName"] : nil }.compact)
        .to include("read-secrets")
      rds = template_of(files["rds.yaml"])
      expect(rds["Parameters"]).to include("BastionSecurityGroupId")
      expect(files["Makefile"]).to include("Rehearsal=$(REHEARSAL)")
    end

    it "has no origin guard, no tunnel egress and one repository" do
      expect(files["Caddyfile"]).not_to include("@origin")
      expect(files["Caddyfile"]).to include("reverse_proxy 127.0.0.1:8080")
      expect(files["box.yaml"]).not_to include("7844")
      resources = template_of(files["box.yaml"])["Resources"]
      expect(resources.keys.grep(/Repository\z/)).to eq(["WebRepository"])
      expect(resources["WebRepository"]["Properties"]["RepositoryName"]).to eq("scratch-fixture-web")
    end

    it "points the box and database stacks at each other by name" do
      expect(files["deploy-box.sh"]).to include("BOX_STACK=hecks-scratch-fixture-box", "RDS_STACK=hecks-scratch-fixture-rds")
      expect(files["Makefile"]).to include("RDS_STACK = hecks-scratch-fixture-rds")
    end
  end

  describe "the full world" do
    let(:files) { cached("full", BOX_WORLDS.fetch("full")).first }

    it "routes each path set to its container and refuses a request without the origin secret" do
      caddy = files["Caddyfile"]
      expect(caddy).to include("@origin header X-Origin-Secret {$ORIGIN_SECRET}")
      expect(caddy).to include("@r1 path /cms/*", "reverse_proxy 127.0.0.1:8081")
      expect(caddy).to include("@r2 path /registrations /registrations/* /webhooks/*", "reverse_proxy 127.0.0.1:8082")
      expect(caddy).to include("respond \"Forbidden\" 403")
    end

    it "lets only a production box overwrite the secrets the world names as writable" do
      policy = template_of(files["box.yaml"])["Resources"]["BoxRole"]["Properties"]["Policies"].first
      write = policy["PolicyDocument"]["Statement"].find { |st| st.is_a?(Hash) && st.key?("Fn::If") }
      expect(write["Fn::If"].first).to eq("IsProduction")
      expect(write["Fn::If"][1]["Action"]).to eq("secretsmanager:PutSecretValue")
      expect(files["box.yaml"]).to include("secret:acme/payments-account-*")
    end

    it "opens outbound 7844 for the tunnel and reads only the declared secrets" do
      box = template_of(files["box.yaml"])
      egress = box["Resources"]["BoxSecurityGroup"]["Properties"]["SecurityGroupEgress"]
      expect(egress.map { |rule| rule["FromPort"] }).to include(5432, 443, 7844)
      statement = box["Resources"]["BoxRole"]["Properties"]["Policies"].first["PolicyDocument"]["Statement"].first
      expect(statement["Resource"].join).to include("secret:acme/*", "secret:acme/origin-secret-*")
    end

    it "names a Graviton AMI for t4g and the region's own DNS suffix for the origin" do
      box = files["box.yaml"]
      expect(box).to include("al2023-ami-kernel-default-arm64")
      expect(box).to include(".eu-west-1.compute.amazonaws.com")
      expect(box).to include("Default: t4g.large", "Default: 50")
    end

    it "sizes the database from the world" do
      rds = files["rds.yaml"]
      expect(rds).to include("Default: db.t4g.medium", "Default: 14", "Default: 50")
    end

    it "gives every container its secrets and the origin secret to the proxy" do
      services = JSON.parse(files["services.json"])
      expect(services["origin"]).to eq("header" => "X-Origin-Secret", "secret" => "acme/origin-secret")
      expect(services["services"]["website"]["secrets"]).to eq("AUTH_SECRET" => "acme/session-secret")
      expect(services["services"]["domain"]["env"]).to eq("HECKS_SCHEMA" => "widgets")
    end
  end

  describe "the default world, without hosting scripts" do
    it "deploys through box_roll.run too, so every deploy leaves a record" do
      makefile = cached("default", BOX_WORLDS.fetch("default")).first.fetch("Makefile")

      expect(makefile).to include("HECKS ?= hecks", "$(HECKS) deploy box_roll.run project=\"$(CURDIR)\"",
                                  "bash ./deploy-box.sh $(TAGS); rc=$$?")
      expect(makefile).not_to include("smoke-after-deploy")
    end
  end

  describe "a world with hosting scripts and a task definition" do
    let(:files) { cached("hosting_taskdef", BOX_WORLDS.fetch("hosting_taskdef")).first }
    let(:deploy) { files["deploy-service.sh"] }
    let(:smoke) { files["smoke-after-deploy.sh"] }

    it "adds the four hosting files and makes `make deploy` the box_roll.run command" do
      expect(files.keys).to include("deploy-service.sh", "smoke-after-deploy.sh", "expected-era", "hosting.mk")
      expect(files["Makefile"]).to include("$(HECKS) deploy box_roll.run project=\"$(CURDIR)\"")
      expect(files["hosting.mk"]).to include("deploy service_roll.run project=\"$(CURDIR)\"")
      expect(files["Makefile"]).to end_with("include hosting.mk\n")
      expect(files["hosting.mk"]).to include("URL     ?= https://widgets.example.com", "SERVICE ?= website")
      expect(files["expected-era"]).to end_with("\na1b2c3\n")
    end

    it "pushes under a unique tag that is never reused" do
      expect(deploy).to include('TAG="${EXISTING_TAG:-${SERVICE_NAME}-$(date -u +%Y%m%d%H%M%S)}"')
      expect(deploy).to include("a tag is never reused")
      expect(deploy).to include('docker --config "$DOCKER_CONFIG_DIR" push "$IMAGE_URI"')
    end

    it "pushes to the repository the active task definition already pulls from" do
      expect(deploy).to include('--task-definition "$FAMILY"', 'ECR_REPOSITORY="${CURRENT_IMAGE#*/}"')
      expect(deploy).to include("FAMILY=widget-platform")
    end

    it "syncs only the container's image-tag parameter and refuses if anything else changed" do
      expect(deploy).to include("IMAGE_STACK=widget-platform", "website) CFN_PARAM_KEY=WebsiteImageTag")
      expect(deploy).to include("domain) CFN_PARAM_KEY=EngineImageTag")
      expect(deploy).to include("UsePreviousValue=true", "--use-previous-template")
      expect(deploy).to include("expected only ${CFN_PARAM_KEY} to change", "No updates are to be performed")
    end

    it "refuses to roll a task definition that does not carry the pushed image, then rolls it and smokes" do
      expect(deploy).to include('"$RUNNING_IMAGE" != "$IMAGE_URI"', "refusing to roll")
      expect(deploy.index('bash ./deploy-box.sh "$TD"')).to be > deploy.index("refusing to roll")
      expect(deploy.rstrip).to end_with("bash ./smoke-after-deploy.sh")
    end

    it "waits for the box to settle before it dispatches the smoke, and follows the run" do
      expect(smoke).to include("BOX_STACK=hecks-widget-shop-box", "WATCHED_STACKS=hecks-widget-shop-box\\ widget-platform")
      expect(smoke).to include("docker compose -f compose.json ps", "two consecutive checks agree")
      expect(smoke).to include('TASK_DEFINITION="${TASKDEF:-widget-platform}"', "runs ${image}, ${TASK_DEFINITION} has ${wanted}")
      expect(smoke.index("wait_for_settled_roll || rc=$?")).to be < smoke.index("run_smoke || rc=$?")
      expect(smoke).to include('WORKFLOW="${WORKFLOW:-smoke-prod.yml}"', 'REPO="${REPO:-acme/widget-shop}"')
      expect(smoke).to include("gh workflow run", "--event workflow_dispatch")
    end

    it "keeps the smoke's exit codes distinct from a failed deploy step's" do
      %w[20 21 22 23].each { |code| expect(smoke).to match(/(return|exit) #{code}\b/) }
    end

    it "names every service the script accepts and refuses any other" do
      expect(deploy).to include("SERVICES='website cms domain'", "unknown service")
    end
  end

  describe "a world with hosting scripts and no task definition" do
    let(:files) { cached("hosting_services", BOX_WORLDS.fetch("hosting_services")).first }

    it "pushes to the container's own repository and names every service's tag in the roll" do
      deploy = files["deploy-service.sh"]
      expect(deploy).to include("website) ECR_REPOSITORY=widget-shop-website", "cms) ECR_REPOSITORY=acme-cms")
      expect(deploy).to include('TAGS+=("${name}=${TAG}")', 'bash ./deploy-box.sh "${TAGS[@]}"')
      expect(deploy).not_to include("CFN_PARAM_KEY", "update-stack")
    end

    it "settles on the box stack and its containers alone" do
      smoke = files["smoke-after-deploy.sh"]
      expect(smoke).to include("TASK_DEFINITION=\"${TASKDEF:-}\"", "WATCHED_STACKS=hecks-widget-shop-box\n",
                               "EXPECTED_SERVICES=website\\ cms\\ caddy")
      expect(files["expected-era"]).to end_with("\n")
    end
  end

  describe "a world without hosting scripts" do
    it "generates none of the hosting files" do
      files = cached("taskdef", BOX_WORLDS.fetch("taskdef")).first
      expect(files.keys).not_to include("deploy-service.sh", "smoke-after-deploy.sh", "expected-era", "hosting.mk")
      expect(files["Makefile"]).not_to include("hosting.mk")
    end
  end

  describe "the reference stack's parts" do
    let(:minimal) { cached("default", BOX_WORLDS.fetch("default")).first }
    let(:full) { cached("full", BOX_WORLDS.fetch("full")).first }
    let(:taskdef) { cached("taskdef", BOX_WORLDS.fetch("taskdef")).first }

    it "lets a bastion reach the database only when one is named" do
      rds = template_of(minimal["rds.yaml"])
      expect(rds["Parameters"]["BastionSecurityGroupId"]["Default"]).to eq("")
      expect(rds["Conditions"]).to include("HasBastion")
      ingress = rds["Resources"]["DbSecurityGroup"]["Properties"]["SecurityGroupIngress"].first
      expect(ingress["Fn::If"].first).to eq("HasBastion")
      source = { "Ref" => "BastionSecurityGroupId" }
      expect(ingress["Fn::If"][1]).to include("FromPort" => 5432, "SourceSecurityGroupId" => source)
    end

    it "ends the Caddyfile with the rehearsal import, and keeps the :80 site free of certificates" do
      [minimal, full, taskdef].each do |files|
        expect(files["Caddyfile"]).to include("auto_https disable_redirects")
        expect(files["Caddyfile"].lines.last).to eq("import /etc/caddy/extra/*\n")
      end
    end

    it "mounts caddy-extra into the proxy and creates it on the box" do
      [minimal, taskdef].each do |files|
        expect(files["render-compose.sh"]).to include('"./caddy-extra:/etc/caddy/extra:ro"')
      end
      expect(minimal["deploy-box.sh"]).to include("caddy-extra && cd")
    end

    it "gives the role read on every bucket and write on a production box, only where declared" do
      policies = template_of(full["box.yaml"])["Resources"]["BoxRole"]["Properties"]["Policies"]
      read, write = policies.last["PolicyDocument"]["Statement"]
      expect(read["Action"]).to eq(%w[s3:GetObject s3:ListBucket])
      expect(read["Resource"].size).to eq(4)
      expect(write["Fn::If"].first).to eq("IsProduction")
      expect(write["Fn::If"][1]["Resource"].size).to eq(1)
      expect(write["Fn::If"][1]["Resource"].first["Fn::Sub"]).to end_with("s3:::acme-media/*")
    end

    it "waits for the box's first boot before it touches Docker, which is installed by user data" do
      roll = minimal["deploy-box.sh"]
      expect(roll).to include("cloud-init status --wait")
      expect(roll.index("cloud-init status --wait")).to be < roll.index("docker compose -f compose.json pull")
      expect(roll.index("cloud-init status --wait")).to be < roll.index("mkdir -p")
    end

    it "lets the Makefile make a throwaway pair, and leaves production the default" do
      make = minimal["Makefile"]
      expect(make).to include("REHEARSAL ?= false", "[REHEARSAL=true]")
      expect(make.scan("Rehearsal=$(REHEARSAL)").size).to eq(2)
    end

    it "tells a rehearsal to restart the proxy, since the admin API is off" do
      expect(minimal["Caddyfile"]).to include("Restart the proxy", "admin off")
    end

    it "grants no S3 access to a world that declares none" do
      policies = template_of(minimal["box.yaml"])["Resources"]["BoxRole"]["Properties"]["Policies"]
      expect(policies.map { |policy| policy["PolicyName"] }).to eq(["read-secrets"])
    end
  end

  describe "the tunnel world" do
    let(:files) { cached("tunnel", BOX_WORLDS.fetch("tunnel")).first }

    it "describes the tunnel in services.json, not as a container" do
      services = JSON.parse(files["services.json"])
      expect(services["tunnel"]).to eq("url" => "http://127.0.0.1:3000", "token_secret" => "scratch/tunnel-token",
                                       "image" => Hecks::Projections::Deploy::Box::Settings::TUNNEL_IMAGE)
      expect(services["services"].keys).to eq(%w[web stats])
    end

    it "opens the egress, lets the role read the token and waits for a connection after the roll" do
      box = template_of(files["box.yaml"])
      expect(box["Resources"]["BoxSecurityGroup"]["Properties"]["SecurityGroupEgress"].map { |r| r["FromPort"] })
        .to include(7844)
      statement = box["Resources"]["BoxRole"]["Properties"]["Policies"].first["PolicyDocument"]["Statement"].first
      expect(statement["Resource"].join).to include("secret:scratch/tunnel-token-*")
      expect(files["deploy-box.sh"]).to include("registered tunnel connection")
    end
  end

  describe "the taskdef world" do
    let(:files) { cached("taskdef", BOX_WORLDS.fetch("taskdef")).first }

    it "records which variables hold the origin secret in services.json" do
      expect(JSON.parse(files["services.json"])["origin"]).to eq(
        "header" => "X-Origin-Secret", "secret" => "widget/origin-secret", "env" => ["WIDGET_ORIGIN"]
      )
    end

    # Runs the generated render-compose.sh in a scratch directory with `aws` replaced by a stub that
    # answers the two calls it makes, so what it refuses is tested without AWS.
    def render(origin_value:, copies:)
      skip "jq is not installed" unless system("jq", "--version", out: File::NULL, err: File::NULL)

      Dir.mktmpdir do |dir|
        files.each { |name, text| File.write(File.join(dir, name), text) }
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "aws"), <<~STUB)
          #!/bin/bash
          case "$1 $2" in
            "ecs describe-task-definition") cat "$STUB_TASK_DEFINITION" ;;
            "secretsmanager get-secret-value") printf '%s\\n' "$STUB_ORIGIN_SECRET" ;;
            *) echo "unexpected aws call: $*" >&2; exit 9 ;;
          esac
        STUB
        File.chmod(0o755, File.join(bin, "aws"))
        containers = [
          { name: "website", image: "img/website", environment: copies.map { |name, value| { name: name, value: value } } },
          { name: "cms", image: "img/cms", environment: [] }
        ]
        File.write(File.join(dir, "task.json"), JSON.generate(containers))
        env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "STUB_TASK_DEFINITION" => File.join(dir, "task.json"),
                "STUB_ORIGIN_SECRET" => origin_value }
        _out, err, status = Open3.capture3(env, "bash", File.join(dir, "render-compose.sh"), "db.example", "arn:db", chdir: dir)
        [status.success?, err, File.exist?(File.join(dir, "compose.json"))]
      end
    end

    it "renders when the container's copy of the origin secret equals the named secret" do
      ok, err, composed = render(origin_value: "s3cret-value", copies: { "WIDGET_ORIGIN" => "s3cret-value" })
      expect(ok).to be(true), err
      expect(composed).to be(true)
    end

    it "refuses when a container's copy differs, naming the container and never printing a value" do
      ok, err, composed = render(origin_value: "s3cret-value", copies: { "WIDGET_ORIGIN" => "other-value" })
      expect(ok).to be(false)
      expect(composed).to be(false)
      expect(err).to include("WIDGET_ORIGIN", "container: website", "widget/origin-secret", "differs")
      expect(err).not_to include("s3cret-value")
      expect(err).not_to include("other-value")
    end

    it "refuses when no container sets a variable the world names, so a typo cannot skip the check" do
      ok, err, composed = render(origin_value: "s3cret-value", copies: { "SOMETHING_ELSE" => "s3cret-value" })
      expect(ok).to be(false)
      expect(composed).to be(false)
      expect(err).to include("origin_env names WIDGET_ORIGIN", "no container")
    end

    it "writes only names and ports to services.json, and the family it renders from" do
      services = JSON.parse(files["services.json"])
      expect(services["task_definition"]).to eq("widget-platform")
      expect(services["services"]).to eq(
        "website" => { "name" => "website", "port" => 8080 }, "cms" => { "name" => "cms", "port" => 8081 }
      )
    end

    it "renders from the task definition and makes no repositories, since its images already have some" do
      expect(files["render-compose.sh"]).to include("aws ecs describe-task-definition", "TD=${3:-widget-platform}")
      expect(files["deploy-box.sh"]).to include("deploy-box.sh [task-definition]", "widget-platform")
      expect(files["Makefile"]).to include("[TASKDEF=family:revision]", "deploy-box.sh $(TASKDEF)")
      resources = template_of(files["box.yaml"])["Resources"]
      expect(resources.keys.grep(/Repository\z/)).to be_empty
      expect(files["box.yaml"]).not_to include("RepositoryUri")
    end
  end

  describe "the migration world" do
    let(:files) { cached("migration", BOX_WORLDS.fetch("migration")).first }
    let(:minimal) { cached("default", BOX_WORLDS.fetch("default")).first }

    it "adds the copy and verify scripts and a runbook to the usual eight files, and only for a migration" do
      extra = %w[restore-to-rds.sh verify-copy.sh MIGRATION.md]
      expect(files.keys).to include(*extra)
      expect(files.keys.size).to eq(minimal.keys.size + 3)
      expect(minimal.keys).not_to include(*extra)
    end

    it "copies each declared schema from the source database into the RDS one" do
      expect(files["restore-to-rds.sh"]).to include('SCHEMAS="widgets widgets_cms"', "SRC_DB=${SRC_DB:-legacy}",
                                                    "DST_DB=${DST_DB:-widgetdb}", "hecks_tr_extract")
      expect(files["verify-copy.sh"]).to include('SCHEMAS="widgets,widgets_cms"', "A_DB=${A_DB:-widgetdb}")
    end

    it "names the stacks and the schemas in the runbook, in the order the steps are run" do
      runbook = files["MIGRATION.md"]
      expect(runbook).to include("`widgets`, `widgets_cms`", "hecks-widget-shop-rds", "make deploy")
      expect(runbook.index("## Before cutover")).to be < runbook.index("## Cutover")
      expect(runbook.index("## Cutover")).to be < runbook.index("## Rollback")
    end

    it "parses as scripts that read the secret's own user name" do
      %w[restore-to-rds.sh verify-copy.sh].each do |script|
        ok, err = syntax_ok?(files[script])
        expect(ok).to be(true), "#{script}: #{err}"
        expect(files[script]).to include(%(.username // "postgres"))
      end
    end

    it "points the runbook's deploy at the task definition when the world names one" do
      files, = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            task_definition "widget-platform"
            containers [{ name: "web", port: 8080 }]
            migration({ schemas: ["widgets"] })
          end
        end
      WORLD
      expect(files["MIGRATION.md"]).to include("make deploy TASKDEF=widget-platform:<revision>")
    end
  end

  describe "a world that is wrong" do
    it "refuses a world with no containers" do
      files, stderr = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
          end
        end
      WORLD
      expect(files).to be_nil
      expect(stderr).to include("at least one container")
    end

    it "refuses an instance type the bluebook does not accept, naming the world's block" do
      files, stderr = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            instance_type "medium"
            containers [{ name: "web", port: 8080 }]
          end
        end
      WORLD
      expect(files).to be_nil
      expect(stderr).to include('deployed_to("AwsBox") is invalid').and include("family.size")
    end

    it "refuses origin_env without an origin secret and a task definition to compare against" do
      files, stderr = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            containers [{ name: "web", port: 8080 }]
            origin_env ["ORIGIN"]
          end
        end
      WORLD
      expect(files).to be_nil
      expect(stderr).to include("origin_env", "origin_secret", "task_definition")
    end

    it "refuses a route to a container that is not declared" do
      files, stderr = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            containers [{ name: "web", port: 8080 }]
            routes [{ container: "ghost", paths: ["/x/*"] }]
          end
        end
      WORLD
      expect(files).to be_nil
      expect(stderr).to include('"ghost" is not a declared container')
    end

    it "uses an x86 image for a non-Graviton instance type" do
      files, = generate(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            instance_type "m5.large"
            containers [{ name: "web", port: 8080 }]
          end
        end
      WORLD
      expect(files["box.yaml"]).to include("al2023-ami-kernel-default-x86_64")
    end
  end
end
