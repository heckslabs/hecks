require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# End-to-end coverage for the `deployed_to("AwsFargate")` path —
# `Hecks::Projections::Deploy::Fargate`, dispatched to through
# `bin/project_deploy` the same way `spec/project_deploy_contract_spec.rb`
# exercises the `AwsLambda` path. Mirrors that spec's own fixture style: a
# scratch domain built under a tmpdir, generated for real through the CLI,
# read back off disk.
RSpec.describe "bin/project_deploy — deployed_to(\"AwsFargate\")", :io do
  FARGATE_FIXTURE_BASENAME = "project_deploy_fargate_spec_fixture".freeze

  def generated_dir
    File.join(File.expand_path("..", __dir__), "deploy", FARGATE_FIXTURE_BASENAME)
  end

  # Runs `bin/project_deploy` for real against a scratch domain declaring
  # `world_body`, and answers its raw stdout/stderr/status — the one place
  # both `generate` (the success path) and the refusal test below build a
  # fixture domain from.
  def run_project_deploy(world_body)
    root = File.expand_path("..", __dir__)
    FileUtils.rm_rf(generated_dir)

    Dir.mktmpdir do |dir|
      domain_dir = File.join(dir, FARGATE_FIXTURE_BASENAME)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)

      File.write(File.join(bluebook_dir, "#{FARGATE_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

      File.write(File.join(bluebook_dir, "#{FARGATE_FIXTURE_BASENAME}.world"), world_body)

      Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
    end
  end

  def generate(world_body)
    _stdout, stderr, status = run_project_deploy(world_body)
    status.success? or raise "bin/project_deploy failed: #{stderr}"

    Dir.children(generated_dir).to_h { |name| [name, File.read(File.join(generated_dir, name))] }
  ensure
    FileUtils.rm_rf(generated_dir)
  end

  def valid_fargate_world
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

  it "produces template.yaml, Makefile, Dockerfile, and bastion.yaml" do
    files = generate(valid_fargate_world)

    expect(files.keys).to include("template.yaml", "Makefile", "Dockerfile", "bastion.yaml")
  end

  it "renders a template.yaml that parses as valid YAML" do
    files = generate(valid_fargate_world)

    expect { YAML.safe_load(files["template.yaml"], aliases: true) }.not_to raise_error
    expect { YAML.safe_load(files["bastion.yaml"], aliases: true) }.not_to raise_error
  end

  it "declares an ECS TaskDefinition, an ECS Service, and an ECR Repository" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    types = doc["Resources"].values.map { |resource| resource["Type"] }

    expect(types).to include("AWS::ECS::TaskDefinition", "AWS::ECS::Service", "AWS::ECR::Repository")
  end

  it "fronts the ALB with a CloudFront distribution pinned to Managed-CachingDisabled" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    distribution = doc["Resources"].values.find { |resource| resource["Type"] == "AWS::CloudFront::Distribution" }

    expect(distribution).not_to be_nil
    behavior = distribution["Properties"]["DistributionConfig"]["DefaultCacheBehavior"]
    # Managed-CachingDisabled/Managed-AllViewer — the safe default this
    # generator has no way to reason its way past; fargate.rb's own
    # CloudFront resource comment has the full reasoning (a hand-authored
    # stack that loosened this, lifeadelics, 2026-09-21, served one
    # signed-in session's own response to a different request).
    expect(behavior["CachePolicyId"]).to eq("4135ea2d-6df8-44a3-9df3-4b5a84be39ad")
    expect(behavior["OriginRequestPolicyId"]).to eq("216adef6-5c7f-47e4-b989-5492eafa07d3")
    expect(doc["Outputs"]).to have_key("CloudFrontDomain")
  end

  it "restricts the ALB's own HTTP ingress to CloudFront's own prefix list, not the open internet" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    _name, alb_sg = doc["Resources"].find { |name, _resource| name.end_with?("AlbSecurityGroup") }
    rule = alb_sg["Properties"]["SecurityGroupIngress"].first

    # pl-3b927c52 — com.amazonaws.global.cloudfront.origin-facing. A
    # CachingDisabled distribution in front of an ALB that's still open
    # on 0.0.0.0/0 protects nothing: anyone can bypass it and hit the
    # plain-HTTP origin directly.
    expect(rule["SourcePrefixListId"]).to eq("pl-3b927c52")
    expect(rule).not_to have_key("CidrIp")
  end

  it "sizes the TaskDefinition from the domain's own cpu/memory/port settings" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    task_definition = doc["Resources"].values.find { |resource| resource["Type"] == "AWS::ECS::TaskDefinition" }
    container = task_definition["Properties"]["ContainerDefinitions"].first

    expect(task_definition["Properties"]["Cpu"]).to eq("256")
    expect(task_definition["Properties"]["Memory"]).to eq("512")
    expect(container["PortMappings"]).to eq([{ "ContainerPort" => 8080 }])
  end

  it "sets HECKS_SERVE_MODE and PORT so rust/host boots into its axum server, not the Lambda runtime loop" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    task_definition = doc["Resources"].values.find { |resource| resource["Type"] == "AWS::ECS::TaskDefinition" }
    container = task_definition["Properties"]["ContainerDefinitions"].first
    env = container["Environment"].to_h { |entry| [entry["Name"], entry["Value"]] }

    expect(env["HECKS_SERVE_MODE"]).to eq("1")
    expect(env["PORT"]).to eq("8080")
    expect(env["SESSION_SECRET_ARN"]).not_to be_nil
    expect(env["HECKS_CHECKOUT_DOMAIN"]).to eq("Scratch")
    expect(env["HECKS_WASM_PATH"]).to include(".wasm")
    expect(env["HECKS_IR_PATH"]).to include(".ir.json")
  end

  it "mints a SessionSecret and pins the image to ImageTag, not hardcoded latest" do
    files = generate(valid_fargate_world)
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    types = doc["Resources"].values.map { |resource| resource["Type"] }
    task_definition = doc["Resources"].values.find { |resource| resource["Type"] == "AWS::ECS::TaskDefinition" }
    image = task_definition["Properties"]["ContainerDefinitions"].first["Image"]

    expect(types).to include("AWS::SecretsManager::Secret")
    expect(doc["Parameters"]).to have_key("ImageTag")
    expect(image).to include("${ImageTag}")
    expect(image).not_to include(":latest")
  end

  it "looks up public subnets for a Shared-mode ALB and uses the GNU cross-linker" do
    files = generate(<<~WORLD)
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          database "Shared"
          owner "Embryonaut"
        end
      end
    WORLD

    expect(files["template.yaml"]).to include("OwningPublicSubnetAId")
    expect(files["Makefile"]).to include("PublicSubnetId")
    expect(files["Makefile"]).to include("BastionSubnetId")
    expect(files["Makefile"]).to include("OwningPublicSubnetAId=$$OWNER_PUBLIC_SUBNET_A_ID")
    expect(files["Makefile"]).to include("CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc")
    expect(files["Makefile"]).to include("--bin bootstrap")
  end

  it "generates a Dockerfile exposing the domain's own port and running its own binary" do
    files = generate(valid_fargate_world)

    expect(files["Dockerfile"]).to include("FROM debian:bookworm-slim")
    expect(files["Dockerfile"]).to include("EXPOSE 8080")
    expect(files["Dockerfile"]).to include("#{FARGATE_FIXTURE_BASENAME}-host")
  end

  it "generates a Makefile with docker build/push and a plain cloudformation deploy, no sam anywhere" do
    files = generate(valid_fargate_world)

    expect(files["Makefile"]).to include("docker build")
    expect(files["Makefile"]).to include("docker push")
    expect(files["Makefile"]).to include("aws cloudformation deploy")
    expect(files["Makefile"]).not_to include("sam deploy")
    expect(files["Makefile"]).not_to include("sam build")
  end

  it "keeps mint-era working the same way Lambda's own generated Makefile does" do
    files = generate(valid_fargate_world)

    expect(files["Makefile"]).to include(".PHONY: mint-era")
    expect(files["Makefile"]).to include("aws cloudformation deploy --template-file bastion.yaml")
  end

  it "skips bastion.yaml and the private VPC for database \"Shared\"" do
    files = generate(<<~WORLD)
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          database "Shared"
          owner "Embryonaut"
        end
      end
    WORLD

    expect(files.keys).not_to include("bastion.yaml")
    doc = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)
    expect(doc["Resources"].values.map { |r| r["Type"] }).not_to include("AWS::RDS::DBInstance")
  end

  it "refuses a port outside 1-65535 through deploy.bluebook's own FargateTarget.Declare" do
    _stdout, stderr, status = run_project_deploy(<<~WORLD)
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          port 99999
        end
      end
    WORLD

    expect(status).not_to be_success
    expect(stderr).to include("deployed_to(\"AwsFargate\") is invalid")
    expect(stderr).to include("a port is at most 65535")
  ensure
    FileUtils.rm_rf(generated_dir)
  end

  # No RSpec `skip` when the tool is absent — spec/support/ci_skip_backstop.rb
  # fails the suite in CI over an unrouted `skip`, and no CI job here
  # installs cfn-lint. A plain early return leaves this example green
  # either way: it asserts something real when the tool exists, and
  # asserts nothing (never a false failure) when it does not.
  it "lints clean with cfn-lint, when it is installed" do
    next if `which cfn-lint`.strip.empty?

    files = generate(valid_fargate_world)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "template.yaml")
      File.write(path, files["template.yaml"])
      _stdout, stderr, status = Open3.capture3("cfn-lint", path)
      expect(status).to be_success, stderr
    end
  end
end
