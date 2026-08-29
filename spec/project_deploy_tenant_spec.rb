require "tmpdir"
require "fileutils"
require "open3"

# THE RUST/LAMBDA SIDE OF MULTI-TENANT HOSTING — see bin/project_deploy's
# own header comment on `--tenant`/`--schema` for the full reasoning:
# rust/host already isolates by HECKS_SCHEMA (main.rs sets `SET
# search_path` from it at boot, journal.rs/dispatch.rs already assume a
# schema-isolated shared instance), and `deployed_to("AwsLambda")
# { schema "..." }` was already a real, generated setting for Shared
# database mode. `--tenant` is the missing per-TENANT generation step —
# the exact same "one deploy per tenant" shape Runtime::TenantCheck's
# own header describes for the Ruby side, applied to CloudFormation
# generation instead of a Ruby boot.
#
# STRUCTURAL, not deployed-to-real-AWS — the same bar
# project_deploy_contract_spec.rb's own header already holds this
# script to: there's nothing to require, so this runs it as a real
# subprocess and reads back what it actually generated.
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
        # DEFAULTED — --schema omitted for bloom, falls back to the
        # tenant slug itself, the same default bin/project_tenant's own
        # Ruby-side generator uses.
        expect(bloom_template).to include("HECKS_SCHEMA: bloom")

        expect(acme_template).not_to include("HECKS_SCHEMA: bloom")
        expect(bloom_template).not_to include("HECKS_SCHEMA: acme_schema")

        # TWO GENUINELY SEPARATE STACKS — different logical ids, so a
        # real `sam deploy` of both stands up two independent Lambdas,
        # not one overwriting the other.
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
