require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require "hecks/projections/deploy/template_diff"

# The hosting scripts `deployed_to("AwsFargate")` can opt in to
# (`hosting_scripts true`): generated for real through `hecks deploy project
# --out`, the way project_deploy_fargate_spec.rb drives the base target, then
# read back off disk. A world that does not opt in must generate exactly what
# it generated before the scripts existed.
RSpec.describe "hecks deploy project — Fargate hosting scripts", :io do
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
    ProjectDeployRunner.run(write_domain(world(extra)), "--out=#{out}", root: root)
  end

  # Generates into a scratch --out directory, once per distinct `extra`, and
  # yields its files by name and the directory they were written to.
  def generate(extra = "")
    out, files = HOSTING_GENERATED[extra] ||= begin
      out = File.join(HOSTING_SCRATCH, "out-#{HOSTING_GENERATED.size}")
      _stdout, stderr, status = run_deploy(extra, out)
      raise "hecks deploy project failed: #{stderr}" unless status.success?

      [out, Dir.children(out).to_h { |name| [name, File.read(File.join(out, name))] }]
    end
    yield(files, out)
  end

  def refusal(extra)
    _stdout, stderr, status = run_deploy(extra, File.join(HOSTING_SCRATCH, "refused"))
    [status, stderr]
  end

  def template_of(files) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(files["template.yaml"])

  # Reads the generated template's task definition into container name =>
  # its ECR repository name and the parameter holding its image tag.
  def template_containers(files)
    resources = template_of(files).fetch("Resources")
    repositories = resources.select { |_id, resource| resource["Type"] == "AWS::ECR::Repository" }
                            .transform_values { |resource| resource["Properties"]["RepositoryName"] }
    task = resources.values.find { |resource| resource["Type"] == "AWS::ECS::TaskDefinition" }
    task["Properties"]["ContainerDefinitions"].to_h do |container|
      repository_id, parameter = container["Image"]["Fn::Sub"].match(/\$\{(\w+)\.RepositoryUri\}:\$\{(\w+)\}/).captures
      [container["Name"], { repository: repositories.fetch(repository_id), parameter: parameter }]
    end
  end

  # Checks that deploy-service.sh accepts exactly the template's containers and
  # resolves each to the repository and parameter the template defines.
  def expect_script_to_match_template(files, defined)
    script = files["deploy-service.sh"]
    parameters = template_of(files).fetch("Parameters").keys

    expect(script).to include("SERVICES='#{defined.keys.join(' ')}'")
    expect(script.scan(/^\s+\S+\) ECR_REPOSITORY=/).size).to eq(defined.size)
    defined.each do |name, names|
      expect(script).to include("#{name}) ECR_REPOSITORY=#{names[:repository]}; CFN_PARAM_KEY=#{names[:parameter]} ;;")
      expect(parameters).to include(names[:parameter])
    end
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
        files, deploy_settings: { region: "no such region" }, plan: nil, stack_name: "a", region: "no such region"
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

    it "names exactly the containers, repositories and tag parameters the template defines" do
      generate(opted_in) do |files, _|
        defined = template_containers(files)

        expect(defined.keys).to eq([HOSTING_FIXTURE_BASENAME])
        expect_script_to_match_template(files, defined)
      end
    end

    describe "with several containers" do
      let(:multi_container_settings) do
        opted_in(<<~SETTINGS)
          domain_container name: "core", repository: "acme-core-image", image_tag_parameter: "CoreTag"
          containers [
            { name: "web", repository: "acme-web", port: 3000, health_path: "/health", image_tag_parameter: "SiteTag" },
            { name: "cms-admin", repository: "acme-cms-admin" }
          ]
          routes [{ container: "web", paths: ["/site/*"], priority: 10 }]
        SETTINGS
      end

      it "follows the template's hash-shaped containers and domain_container" do
        generate(multi_container_settings) do |files, _|
          defined = template_containers(files)

          expect(defined).to eq(
            "core"      => { repository: "acme-core-image", parameter: "CoreTag" },
            "web"       => { repository: "acme-web", parameter: "SiteTag" },
            "cms-admin" => { repository: "acme-cms-admin", parameter: "CmsAdminImageTag" }
          )
          expect(files["deploy-service.sh"]).to include("SERVICES='core web cms-admin'")
          expect_script_to_match_template(files, defined)
        end
      end

      it "makes the Makefile push the domain image to the repository and parameter the template names" do
        generate(multi_container_settings) do |files, _|
          makefile = files["Makefile"]

          expect(makefile).to include("docker build --platform linux/arm64 -t acme-core-image:$(IMAGE_TAG)")
          expect(makefile).to include(".amazonaws.com/acme-core-image:$(IMAGE_TAG)")
          expect(makefile).to include("--parameter-overrides CoreTag=$(IMAGE_TAG)")
          expect(makefile).not_to match(%r{\bImageTag=|amazonaws\.com/#{HOSTING_FIXTURE_BASENAME}:})
          expect(files["hosting.mk"]).to include("SERVICE         ?= core")
        end
      end

      it "refuses the container name list the scripts used to take" do
        status, stderr = refusal(opted_in("containers [\"web\"]\n"))

        expect(status).not_to be_success
        expect(stderr).to include("containers[0] must be a hash")
      end
    end

    it "takes the cluster and service the template names when the world renames them" do
      generate(opted_in("names cluster: \"acme-shared-cluster\", service: \"acme-shared-svc\"\n")) do |files, _|
        resources = template_of(files).fetch("Resources").values
        cluster = resources.find { |resource| resource["Type"] == "AWS::ECS::Cluster" }
        service = resources.find { |resource| resource["Type"] == "AWS::ECS::Service" }

        expect(files["deploy-service.sh"]).to include("CLUSTER=#{cluster['Properties']['ClusterName']}",
                                                      "ECS_SERVICE=#{service['Properties']['ServiceName']}")
        expect(files["deploy-service.sh"]).to include("CLUSTER=acme-shared-cluster", "ECS_SERVICE=acme-shared-svc")
      end
    end

    it "leaves the default Makefile deploy on ImageTag and the domain-named repository" do
      generate(opted_in) do |files, _|
        expect(files["Makefile"]).to include("-t #{HOSTING_FIXTURE_BASENAME}:$(IMAGE_TAG)",
                                             "--parameter-overrides ImageTag=$(IMAGE_TAG)")
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

    describe "with hecks_release \"edge\", the tag that follows main" do
      let(:edge_world) { opted_in.sub('hecks_release "2.5.1"', 'hecks_release "edge"') }

      it "is the one name accepted that is not a version, and anything else is still refused" do
        generate(edge_world) { |files, _| expect(files["hosting.mk"]).to include("HECKS_VERSION   ?= edge") }

        status, stderr = refusal(opted_in.sub('hecks_release "2.5.1"', 'hecks_release "latest"'))

        expect(status).not_to be_success
        expect(stderr).to include("hecks_release")
      end

      it "fetches the edge tag afresh and does not demand an exact release tag" do
        skip "make is not installed" unless system("command -v make >/dev/null 2>&1")

        generate(edge_world) do |_files, out|
          output, status = Open3.capture2e("make", "-n", "-C", out, "hecks-release", "HECKS_CACHE_DIR=#{out}/cache")

          expect(status).to be_success, output
          expect(output).to include("--branch edge", "+refs/tags/edge:refs/tags/edge")
          expect(output).not_to include("describe --tags --exact-match")
        end
      end

      # Runs git in the throwaway repository that stands in for the hecks source.
      def source_git(source, *args)
        out, status = Open3.capture2e("git", "-C", source, *args)
        raise out unless status.success?

        out.strip
      end

      # Commits one new file and points the edge tag at it; answers the short commit.
      def commit_and_move_edge(source, file)
        File.write(File.join(source, file), "x")
        source_git(source, "add", "-A")
        source_git(source, "commit", "--quiet", "-m", file)
        source_git(source, "tag", "--force", "edge")
        source_git(source, "rev-parse", "--short", "HEAD")
      end

      def build_edge(out, source)
        Open3.capture2e("make", "-C", out, "hecks-release", "HECKS_CACHE_DIR=#{out}/cache",
                        "HECKS_SOURCE=file://#{source}")
      end

      it "follows the tag when it moves, and says which commit it built" do
        skip "make or git is not installed" unless system("command -v make >/dev/null 2>&1 && command -v git >/dev/null 2>&1")

        Dir.mktmpdir("hecks-edge-source") do |source|
          source_git(source, "init", "--quiet")
          source_git(source, "config", "user.email", "spec@example.test")
          source_git(source, "config", "user.name", "Spec")
          FileUtils.mkdir_p(File.join(source, "exe"))
          first = commit_and_move_edge(source, "exe/hecks")

          generate(edge_world) do |_files, out|
            output, status = build_edge(out, source)
            expect(status).to be_success, output
            expect(output).to include("hecks edge at #{first}")

            second = commit_and_move_edge(source, "later")
            output, status = build_edge(out, source)
            expect(status).to be_success, output
            expect(output).to include("hecks edge at #{second}")
          end
        end
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
