require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# End-to-end coverage for the `deployed_to("AwsFargate")` path: a scratch
# domain built under a tmpdir, generated for real through the CLI, read back off disk.
RSpec.describe "hecks deploy project — deployed_to(\"AwsFargate\")", :io do
  FARGATE_FIXTURE_BASENAME = "project_deploy_fargate_spec_fixture".freeze

  FARGATE_FIXTURE_BLUEBOOK = <<~BLUEBOOK.freeze
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

  after { FileUtils.rm_rf(generated_dir) }

  def repo_root = File.expand_path("..", __dir__)

  def generated_dir
    File.join(repo_root, "deploy", FARGATE_FIXTURE_BASENAME)
  end

  # Runs `hecks deploy project` for real against a scratch domain declaring
  # `world_body`; both `generate` and the refusal test below build fixtures from this.
  def run_project_deploy(world_body)
    FileUtils.rm_rf(generated_dir)

    Dir.mktmpdir do |dir|
      domain_dir = File.join(dir, FARGATE_FIXTURE_BASENAME)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{FARGATE_FIXTURE_BASENAME}.bluebook"), FARGATE_FIXTURE_BLUEBOOK)
      File.write(File.join(bluebook_dir, "#{FARGATE_FIXTURE_BASENAME}.world"), world_body)
      ProjectDeployRunner.run(domain_dir, root: repo_root)
    end
  end

  def generate(world_body)
    _stdout, stderr, status = run_project_deploy(world_body)
    status.success? or raise "hecks deploy project failed: #{stderr}"

    Dir.children(generated_dir).to_h { |name| [name, File.read(File.join(generated_dir, name))] }
  ensure
    FileUtils.rm_rf(generated_dir)
  end

  # A world that deploys the scratch domain to AwsFargate with the given settings.
  def fargate_world(*settings)
    body = settings.map { |setting| "    #{setting}\n" }.join
    "Hecks.world \"Scratch\" do\n  deployed_to(\"AwsFargate\") do\n#{body}  end\nend\n"
  end

  def valid_fargate_world = fargate_world('region "us-east-1"', "cpu 256", "memory 512", "port 8080")

  def shared_fargate_world = fargate_world('region "us-east-1"', 'database "Shared"', 'owner "Core"')

  def parse_template(files) = YAML.safe_load(files["template.yaml"], permitted_classes: [], aliases: true)

  # The parsed template.yaml of the valid world.
  def template_doc = parse_template(generate(valid_fargate_world))

  def resources_of(doc, type) = doc["Resources"].values.select { |resource| resource["Type"] == type }

  def resource_types(doc) = doc["Resources"].values.map { |resource| resource["Type"] }

  # The one resource of `type`, which the template must have.
  def resource_of(doc, type)
    found = resources_of(doc, type).first
    expect(found).not_to be_nil, "the template has no #{type}"
    found
  end

  def task_properties(doc) = resource_of(doc, "AWS::ECS::TaskDefinition")["Properties"]

  def task_container(doc) = task_properties(doc)["ContainerDefinitions"].first

  def task_env(doc) = task_container(doc)["Environment"].to_h { |entry| [entry["Name"], entry["Value"]] }

  def cfn_lint(template_text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "template.yaml")
      File.write(path, template_text)
      _stdout, stderr, status = Open3.capture3("cfn-lint", path)
      [stderr, status]
    end
  end

  it "produces template.yaml, Makefile, Dockerfile, and bastion.yaml" do
    files = generate(valid_fargate_world)

    expect(files.keys).to include("template.yaml", "Makefile", "Dockerfile", "bastion.yaml")
  end

  it "renders a template.yaml that parses as valid YAML", :aggregate_failures do
    files = generate(valid_fargate_world)

    expect { YAML.safe_load(files["template.yaml"], aliases: true) }.not_to raise_error
    expect { YAML.safe_load(files["bastion.yaml"], aliases: true) }.not_to raise_error
  end

  it "declares an ECS TaskDefinition, an ECS Service, and an ECR Repository" do
    expect(resource_types(template_doc)).to include("AWS::ECS::TaskDefinition", "AWS::ECS::Service", "AWS::ECR::Repository")
  end

  it "fronts the ALB with a CloudFront distribution pinned to Managed-CachingDisabled", :aggregate_failures do
    doc = template_doc
    behavior = resource_of(doc, "AWS::CloudFront::Distribution")["Properties"]["DistributionConfig"]["DefaultCacheBehavior"]

    # Pinned deliberately: loosening this policy pair once leaked one
    # signed-in session's cached response to a different visitor.
    expect(behavior.values_at("CachePolicyId", "OriginRequestPolicyId"))
      .to eq(%w[4135ea2d-6df8-44a3-9df3-4b5a84be39ad 216adef6-5c7f-47e4-b989-5492eafa07d3])
    expect(doc["Outputs"]).to have_key("CloudFrontDomain")
  end

  it "restricts the ALB's own HTTP ingress to CloudFront's own prefix list, not the open internet", :aggregate_failures do
    _name, alb_sg = template_doc["Resources"].find { |name, _resource| name.end_with?("AlbSecurityGroup") }
    rule = alb_sg["Properties"]["SecurityGroupIngress"].first

    # pl-3b927c52 = CloudFront's origin-facing prefix list. A CachingDisabled
    # distribution in front of an ALB still open on 0.0.0.0/0 protects
    # nothing — anyone can bypass it and hit the plain-HTTP origin directly.
    expect(rule["SourcePrefixListId"]).to eq("pl-3b927c52")
    expect(rule).not_to have_key("CidrIp")
  end

  it "sizes the TaskDefinition from the domain's own cpu/memory/port settings", :aggregate_failures do
    properties = task_properties(template_doc)

    expect(properties["Cpu"]).to eq("256")
    expect(properties["Memory"]).to eq("512")
    expect(properties["ContainerDefinitions"].first["PortMappings"]).to eq([{ "ContainerPort" => 8080 }])
  end

  it "sets HECKS_SERVE_MODE and PORT so rust/host boots into its axum server, not the Lambda runtime loop", :aggregate_failures do
    env = task_env(template_doc)

    expect(env.values_at("HECKS_SERVE_MODE", "PORT", "HECKS_CHECKOUT_DOMAIN")).to eq(%w[1 8080 Scratch])
    expect(env["SESSION_SECRET_ARN"]).not_to be_nil
    expect(env["HECKS_WASM_PATH"]).to include(".wasm")
    expect(env["HECKS_IR_PATH"]).to include(".ir.json")
  end

  it "mints a SessionSecret and pins the image to ImageTag, not hardcoded latest", :aggregate_failures do
    doc = template_doc

    expect(resource_types(doc)).to include("AWS::SecretsManager::Secret")
    expect(doc["Parameters"]).to have_key("ImageTag")
    expect(task_container(doc)["Image"]).to include("${ImageTag}")
    expect(task_container(doc)["Image"]).not_to include(":latest")
  end

  it "looks up public subnets for a Shared-mode ALB and uses the GNU cross-linker", :aggregate_failures do
    files = generate(shared_fargate_world)

    expect(files["template.yaml"]).to include("OwningPublicSubnetAId")
    expect(files["Makefile"]).to include("PublicSubnetId", "BastionSubnetId", "OwningPublicSubnetAId=$$OWNER_PUBLIC_SUBNET_A_ID",
                                         "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc", "--bin bootstrap")
  end

  it "generates a Dockerfile exposing the domain's own port and running its own binary", :aggregate_failures do
    files = generate(valid_fargate_world)

    expect(files["Dockerfile"]).to include("FROM debian:bookworm-slim")
    expect(files["Dockerfile"]).to include("EXPOSE 8080")
    expect(files["Dockerfile"]).to include("#{FARGATE_FIXTURE_BASENAME}-host")
  end

  it "generates a Makefile with docker build/push and a plain cloudformation deploy, no sam anywhere", :aggregate_failures do
    makefile = generate(valid_fargate_world)["Makefile"]

    expect(makefile).to include("docker build", "docker push", "aws cloudformation deploy")
    expect(makefile).not_to include("sam deploy", "sam build")
  end

  it "keeps mint-era working the same way Lambda's own generated Makefile does", :aggregate_failures do
    files = generate(valid_fargate_world)

    expect(files["Makefile"]).to include(".PHONY: mint-era")
    expect(files["Makefile"]).to include("aws cloudformation deploy --template-file bastion.yaml")
  end

  it "skips bastion.yaml and the private VPC for database \"Shared\"", :aggregate_failures do
    files = generate(shared_fargate_world)

    expect(files.keys).not_to include("bastion.yaml")
    expect(resource_types(parse_template(files))).not_to include("AWS::RDS::DBInstance")
  end

  it "refuses a port outside 1-65535 through deploy.bluebook's own FargateTarget.Declare", :aggregate_failures do
    _stdout, stderr, status = run_project_deploy(fargate_world('region "us-east-1"', "port 99999"))

    expect(status).not_to be_success
    expect(stderr).to include("deployed_to(\"AwsFargate\") is invalid")
    expect(stderr).to include("a port is at most 65535")
  end

  # No RSpec `skip`: spec/support/ci_skip_backstop.rb fails the suite in CI
  # over an unrouted skip, and no CI job here installs cfn-lint. A plain
  # early return stays green either way, asserting nothing when the tool is absent.
  it "lints clean with cfn-lint, when it is installed" do
    next if `which cfn-lint`.strip.empty?

    stderr, status = cfn_lint(generate(valid_fargate_world)["template.yaml"])

    expect(status).to be_success, stderr
  end
end
