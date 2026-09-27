require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# The hosting scripts `deployed_to("AwsFargate")` can opt in to
# (`hosting_scripts true`): generated for real through `bin/project_deploy
# --out`, the way project_deploy_fargate_spec.rb drives the base target, then
# read back off disk. A world that does not opt in must generate exactly what
# it generated before the scripts existed.
RSpec.describe "bin/project_deploy — Fargate hosting scripts", :io do
  HOSTING_FIXTURE_BASENAME = "project_deploy_hosting_spec_fixture".freeze

  def root = File.expand_path("..", __dir__)

  # One scratch directory for the whole file: the generated files embed the
  # domain's path, so two generations only compare equal from the same one.
  HOSTING_SCRATCH = Dir.mktmpdir
  HOSTING_GENERATED = Hash.new(nil)

  after(:all) { FileUtils.rm_rf(HOSTING_SCRATCH) }

  def write_domain(world_body)
    bluebook_dir = File.join(HOSTING_SCRATCH, HOSTING_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "#{HOSTING_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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
    File.write(File.join(bluebook_dir, "#{HOSTING_FIXTURE_BASENAME}.world"), world_body)
    File.join(HOSTING_SCRATCH, HOSTING_FIXTURE_BASENAME)
  end

  def world(extra = "")
    <<~WORLD
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          cpu 256
          memory 512
          port 8080
          stack_prefix "acme"
      #{extra.lines.map { |line| "    #{line}" }.join}
        end
      end
    WORLD
  end

  def run_deploy(extra, out)
    Open3.capture3("ruby", File.join(root, "bin/project_deploy"), write_domain(world(extra)), "--out=#{out}")
  end

  # Generates into a scratch --out directory, once per distinct `extra`, and
  # yields its files by name and the directory they were written to.
  def generate(extra = "")
    out, files = HOSTING_GENERATED[extra] ||= begin
      out = File.join(HOSTING_SCRATCH, "out-#{HOSTING_GENERATED.size}")
      _stdout, stderr, status = run_deploy(extra, out)
      raise "bin/project_deploy failed: #{stderr}" unless status.success?

      [out, Dir.children(out).to_h { |name| [name, File.read(File.join(out, name))] }]
    end
    yield(files, out)
  end

  def refusal(extra)
    _stdout, stderr, status = run_deploy(extra, File.join(HOSTING_SCRATCH, "refused"))
    [status, stderr]
  end

  def opted_in(extra = "")
    <<~SETTINGS + extra
      hosting_scripts true
      hecks_release "2.5.1"
    SETTINGS
  end

  let(:pinned_world) do
    opted_in(<<~SETTINGS)
      smoke_repo "acme-org/acme-site"
      smoke_workflow "smoke-prod.yml"
      expected_eras ["aaa111", "bbb222"]
    SETTINGS
  end

  describe "without the opt-in" do
    it "generates exactly the files the target always did" do
      generate { |files, _| expect(files.keys).to contain_exactly("template.yaml", "Makefile", "Dockerfile", "bastion.yaml") }
    end

    it "ignores the hosting settings when hosting_scripts is not true" do
      base = generate { |files, _| files }
      ignored = generate("hecks_release \"2.5.1\"\nsmoke_repo \"acme-org/acme-site\"\nhosting_scripts false\n") do |files, _|
        files
      end

      expect(ignored).to eq(base)
    end

    it "returns the very same file map from Scripts.extend_files" do
      require "hecks/projections/deploy/scripts"
      files = { "Makefile" => "x" }

      result = Hecks::Projections::Deploy::Scripts.extend_files(
        files, deploy_settings: { region: "no such region" }, infra_name: "a", stack_name: "a", region: "no such region"
      )

      expect(result).to equal(files)
    end
  end

  describe "with hosting_scripts true" do
    it "adds only the scripts, hosting.mk and expected-era, and leaves the other files byte-identical" do
      base = generate { |files, _| files }
      opted = generate(pinned_world) { |files, _| files }

      expect(opted.keys - base.keys).to contain_exactly("hosting.mk", "deploy-service.sh", "smoke-after-deploy.sh",
                                                        "expected-era")
      %w[template.yaml Dockerfile bastion.yaml].each { |name| expect(opted[name]).to eq(base[name]) }
      expect(opted["Makefile"]).to start_with(base["Makefile"])
      expect(opted["Makefile"].delete_prefix(base["Makefile"])).to eq("\ninclude hosting.mk\n")
    end

    it "requires a pinned hecks_release" do
      status, stderr = refusal("hosting_scripts true\n")

      expect(status).not_to be_success
      expect(stderr).to include("hecks_release")
    end

    it "refuses a value that would not be safe inside a shell script" do
      status, stderr = refusal(opted_in("smoke_repo \"acme org/site; rm -rf /\"\n"))

      expect(status).not_to be_success
      expect(stderr).to include("smoke_repo")
    end

    it "defaults the names to the ones the generated template gives its own resources" do
      generate(opted_in) do |files, _|
        script = files["deploy-service.sh"]
        template = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
        cluster = template["Resources"].values.find { |resource| resource["Type"] == "AWS::ECS::Cluster" }

        expect(script).to include("CLUSTER=#{cluster['Properties']['ClusterName']}")
        expect(script).to include("ECS_SERVICE=acme-#{HOSTING_FIXTURE_BASENAME}")
        expect(script).to include("ECR_REPOSITORY=#{HOSTING_FIXTURE_BASENAME}; CFN_PARAM_KEY=ImageTag")
        expect(template["Parameters"]).to have_key("ImageTag")
      end
    end

    it "writes each setting into the scripts" do
      settings = pinned_world + <<~SETTINGS
        ecs_cluster "acme-cluster"
        ecs_service "acme-svc"
        smoke_ref "release"
      SETTINGS
      generate(settings) do |files, _|
        deploy = files["deploy-service.sh"]
        smoke = files["smoke-after-deploy.sh"]

        expect(deploy).to include("REGION=us-east-1", "CLUSTER=acme-cluster", "ECS_SERVICE=acme-svc",
                                  "STACK=acme-#{HOSTING_FIXTURE_BASENAME}")
        expect(smoke).to include("REPO=\"${REPO:-acme-org/acme-site}\"", "WORKFLOW=\"${WORKFLOW:-smoke-prod.yml}\"",
                                 "SMOKE_REF=\"${SMOKE_REF:-release}\"", "CLUSTER=acme-cluster",
                                 "STACK=acme-#{HOSTING_FIXTURE_BASENAME}")
      end
    end

    it "leaves the repository and workflow to the environment when they are not set" do
      generate(opted_in) do |files, _|
        expect(files["smoke-after-deploy.sh"]).to include("REPO=\"${REPO:-}\"", "WORKFLOW=\"${WORKFLOW:-}\"")
      end
    end

    it "maps every container to its repository and image tag parameter" do
      settings = opted_in(<<~SETTINGS)
        containers ["web", "cms-admin", "domain"]
        ecr_repositories "domain" => "acme-domain-image"
        image_tag_parameters "web" => "SiteTag"
      SETTINGS
      generate(settings) do |files, _|
        script = files["deploy-service.sh"]

        expect(script).to include("SERVICES='web cms-admin domain'")
        expect(script).to include("web) ECR_REPOSITORY=#{HOSTING_FIXTURE_BASENAME}-web; CFN_PARAM_KEY=SiteTag ;;")
        expect(script).to include("cms-admin) ECR_REPOSITORY=#{HOSTING_FIXTURE_BASENAME}-cms-admin;",
                                  "CFN_PARAM_KEY=CmsAdminImageTag ;;")
        expect(script).to include("domain) ECR_REPOSITORY=acme-domain-image; CFN_PARAM_KEY=DomainImageTag ;;")
      end
    end

    it "derives the account from sts and hardcodes none" do
      generate(pinned_world) do |files, _|
        scripts = files.values_at("deploy-service.sh", "smoke-after-deploy.sh", "hosting.mk")

        expect(files["deploy-service.sh"]).to include("aws sts get-caller-identity")
        scripts.each { |text| expect(text).not_to match(/\b\d{12}\b/) }
      end
    end

    it "starts every script with strict mode" do
      generate(pinned_world) do |files, _|
        %w[deploy-service.sh smoke-after-deploy.sh].each do |name|
          expect(files[name]).to start_with("#!/usr/bin/env bash\n")
          expect(files[name]).to include("\nset -euo pipefail\n")
        end
      end
    end

    it "parses under bash and, where installed, passes shellcheck" do
      generate(pinned_world) do |files, out|
        %w[deploy-service.sh smoke-after-deploy.sh].each do |name|
          _o, err, status = Open3.capture3("bash", "-n", File.join(out, name))
          expect(status).to be_success, "bash -n #{name}: #{err}"
        end
        next unless system("command -v shellcheck >/dev/null 2>&1")

        scripts = %w[deploy-service.sh smoke-after-deploy.sh].map { |name| File.join(out, name) }
        output, status = Open3.capture2e("shellcheck", *scripts)
        expect(status).to be_success, output
      end
    end

    it "pins the hecks release without any absolute path" do
      generate(pinned_world) do |files, out|
        mk = files["hosting.mk"]

        expect(mk).to include("HECKS_VERSION   ?= 2.5.1")
        expect(mk).to include("HECKS_ROOT      ?= $(HECKS_CACHE_DIR)/hecks-$(HECKS_VERSION)")
        expect(mk).to include("ROOT            := $(HECKS_ROOT)")
        expect(mk).not_to include(root, out, "/Users/")
      end
    end

    it "parses under make, with the fetch step reading the pinned tag" do
      skip "make is not installed" unless system("command -v make >/dev/null 2>&1")

      generate(pinned_world) do |_files, out|
        output, status = Open3.capture2e("make", "-n", "-C", out, "hecks-release", "HECKS_CACHE_DIR=#{out}/cache")

        expect(status).to be_success, output
        expect(output).to include("git clone --quiet --depth 1 --branch \"v2.5.1\"")
      end
    end

    it "lists the expected eras beside the roll procedure" do
      generate(pinned_world) do |files, _|
        require "hecks/ports/persistence/plugins/era/expected_era"

        expect(Hecks::Runtime::EraCheck::ExpectedEra.parse(files["expected-era"])).to eq(%w[aaa111 bbb222])
        expect(files["expected-era"]).to include("Changing the era on a roll")
      end
    end

    it "lists no era when none is set, so a host is only checked to report one" do
      generate(opted_in) do |files, _|
        require "hecks/ports/persistence/plugins/era/expected_era"

        expect(Hecks::Runtime::EraCheck::ExpectedEra.parse(files["expected-era"])).to eq([])
      end
    end
  end
end
