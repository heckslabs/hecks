require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# Runs `hecks deploy project` tenant=/schema= in this process and checks the generated per-tenant
# CloudFormation (one deploy per tenant, isolated by HECKS_SCHEMA); structural, not deployed.
RSpec.describe "hecks deploy project tenant=", :io do
  TENANT_FIXTURE_BASENAME = "project_deploy_tenant_spec_fixture".freeze

  TENANT_FIXTURE_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "TenantDeploy" do
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

  TENANT_FIXTURE_WORLD = <<~WORLD.freeze
    Hecks.world "TenantDeploy" do
      deployed_to("AwsLambda") do
        region "us-east-1"
      end
    end
  WORLD

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, TENANT_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "#{TENANT_FIXTURE_BASENAME}.bluebook"), TENANT_FIXTURE_BLUEBOOK)
    File.write(File.join(bluebook_dir, "#{TENANT_FIXTURE_BASENAME}.world"), TENANT_FIXTURE_WORLD)
    File.join(dir, TENANT_FIXTURE_BASENAME)
  end

  def run_project_deploy(domain_dir, *flags)
    ProjectDeployRunner.run(domain_dir, *flags, root: root)
  end

  def cleanup(*stack_names)
    stack_names.each { |name| FileUtils.rm_rf(File.join(root, "deploy", name)) }
  end

  def acme_stack = "#{TENANT_FIXTURE_BASENAME}-acme"

  def bloom_stack = "#{TENANT_FIXTURE_BASENAME}-bloom"

  # Yields a throwaway domain, with the generated stacks named removed before and after.
  def with_domain_and_stacks(*stack_names)
    Dir.mktmpdir do |dir|
      cleanup(*stack_names)

      begin
        yield write_fixture(dir)
      ensure
        cleanup(*stack_names)
      end
    end
  end

  def generate_tenant!(domain_dir, tenant, *flags)
    _out, err, status = run_project_deploy(domain_dir, "--tenant=#{tenant}", *flags)
    status.success? or raise "hecks deploy project tenant==#{tenant} failed: #{err}"
  end

  # Acme names its schema; Bloom leaves it out, so it falls back to the tenant slug.
  def generate_both_tenants(domain_dir)
    generate_tenant!(domain_dir, "acme", "--schema=acme_schema")
    generate_tenant!(domain_dir, "bloom")
  end

  def template_of(stack) = File.read(File.join(root, "deploy", stack, "template.yaml"))

  it "gives each tenant's stack its own HECKS_SCHEMA, falling back to the slug", :aggregate_failures do
    with_domain_and_stacks(acme_stack, bloom_stack) do |domain_dir|
      generate_both_tenants(domain_dir)

      expect(template_of(acme_stack)).to include("HECKS_SCHEMA: acme_schema")
      expect(template_of(bloom_stack)).to include("HECKS_SCHEMA: bloom")
    end
  end

  it "keeps one tenant's schema out of the other's stack", :aggregate_failures do
    with_domain_and_stacks(acme_stack, bloom_stack) do |domain_dir|
      generate_both_tenants(domain_dir)

      expect(template_of(acme_stack)).not_to include("HECKS_SCHEMA: bloom")
      expect(template_of(bloom_stack)).not_to include("HECKS_SCHEMA: acme_schema")
    end
  end

  it "generates a separate stack per tenant: distinct logical ids, so two Lambdas", :aggregate_failures do
    with_domain_and_stacks(acme_stack, bloom_stack) do |domain_dir|
      generate_both_tenants(domain_dir)

      expect(template_of(acme_stack)).to include("FunctionName: hecks-#{acme_stack}")
      expect(template_of(bloom_stack)).to include("FunctionName: hecks-#{bloom_stack}")
    end
  end

  it "refuses --schema given with no --tenant to scope it to", :aggregate_failures do
    with_domain_and_stacks do |domain_dir|
      _out, err, status = run_project_deploy(domain_dir, "--schema=acme_schema")

      expect(status).not_to be_success
      expect(err).to include("--schema needs --tenant")
    end
  end

  def deployed_acme_stacks = Dir.glob(File.join(root, "deploy", "#{TENANT_FIXTURE_BASENAME}-acme*"))

  it "re-running for the same tenant regenerates the SAME stack, not a second one" do
    with_domain_and_stacks(acme_stack) do |domain_dir|
      2.times { run_project_deploy(domain_dir, "--tenant=acme") }

      expect(deployed_acme_stacks).to eq([File.join(root, "deploy", acme_stack)])
    end
  end
end
