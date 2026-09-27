require "tmpdir"
require "fileutils"
require "open3"

# Runs bin/project_deploy --tenant/--schema as a subprocess and checks the generated per-tenant
# CloudFormation (one deploy per tenant, isolated by HECKS_SCHEMA); structural, not deployed.
RSpec.describe "bin/project_deploy --tenant", :io do
  TENANT_FIXTURE_BASENAME = "project_deploy_tenant_spec_fixture".freeze

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, TENANT_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)

    File.write(File.join(bluebook_dir, "#{TENANT_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

    File.write(File.join(bluebook_dir, "#{TENANT_FIXTURE_BASENAME}.world"), <<~WORLD)
      Hecks.world "TenantDeploy" do
        deployed_to("AwsLambda") do
          region "us-east-1"
        end
      end
    WORLD

    File.join(dir, TENANT_FIXTURE_BASENAME)
  end

  def run_project_deploy(domain_dir, *flags)
    Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir, *flags)
  end

  def cleanup(*stack_names)
    stack_names.each { |name| FileUtils.rm_rf(File.join(root, "deploy", name)) }
  end

  it "generates a separate stack per tenant, each carrying its own HECKS_SCHEMA" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)

      acme_stack  = "#{TENANT_FIXTURE_BASENAME}-acme"
      bloom_stack = "#{TENANT_FIXTURE_BASENAME}-bloom"
      cleanup(acme_stack, bloom_stack)

      begin
        _out, err_acme, status_acme = run_project_deploy(domain_dir, "--tenant=acme", "--schema=acme_schema")
        status_acme.success? or raise "bin/project_deploy --tenant=acme failed: #{err_acme}"

        _out, err_bloom, status_bloom = run_project_deploy(domain_dir, "--tenant=bloom")
        status_bloom.success? or raise "bin/project_deploy --tenant=bloom failed: #{err_bloom}"

        acme_template  = File.read(File.join(root, "deploy", acme_stack, "template.yaml"))
        bloom_template = File.read(File.join(root, "deploy", bloom_stack, "template.yaml"))

        expect(acme_template).to include("HECKS_SCHEMA: acme_schema")
        # --schema omitted falls back to the tenant slug, as bin/project_tenant does.
        expect(bloom_template).to include("HECKS_SCHEMA: bloom")

        expect(acme_template).not_to include("HECKS_SCHEMA: bloom")
        expect(bloom_template).not_to include("HECKS_SCHEMA: acme_schema")

        # Two separate stacks: distinct logical ids, so deploying both gives two Lambdas.
        expect(acme_template).to include("FunctionName: hecks-#{acme_stack}")
        expect(bloom_template).to include("FunctionName: hecks-#{bloom_stack}")
      ensure
        cleanup(acme_stack, bloom_stack)
      end
    end
  end

  it "refuses --schema given with no --tenant to scope it to" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)

      _out, err, status = run_project_deploy(domain_dir, "--schema=acme_schema")

      expect(status).not_to be_success
      expect(err).to include("--schema needs --tenant")
    end
  end

  it "re-running for the same tenant regenerates the SAME stack, not a second one" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)
      acme_stack = "#{TENANT_FIXTURE_BASENAME}-acme"
      cleanup(acme_stack)

      begin
        run_project_deploy(domain_dir, "--tenant=acme")
        run_project_deploy(domain_dir, "--tenant=acme")

        expect(Dir.glob(File.join(root, "deploy", "#{TENANT_FIXTURE_BASENAME}-acme*"))).to eq(
          [File.join(root, "deploy", acme_stack)]
        )
      ensure
        cleanup(acme_stack)
      end
    end
  end
end
