require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# `hecks deploy project out=<dir>` writes a domain's recipe beside the
# client that owns it instead of into this repo's deploy/. Structural,
# like project_deploy_tenant_spec.rb: runs the generator in this process
# against a throwaway domain and reads back what it wrote.
RSpec.describe "hecks deploy project out=", :io do
  OUT_FIXTURE_BASENAME = "project_deploy_out_spec_fixture".freeze

  OUT_FIXTURE_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "OutDeploy" do
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

  OUT_FIXTURE_WORLD = <<~WORLD.freeze
    Hecks.world "OutDeploy" do
      deployed_to("AwsLambda") do
        region "us-east-1"
      end
    end
  WORLD

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, OUT_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "#{OUT_FIXTURE_BASENAME}.bluebook"), OUT_FIXTURE_BLUEBOOK)
    File.write(File.join(bluebook_dir, "#{OUT_FIXTURE_BASENAME}.world"), OUT_FIXTURE_WORLD)
    File.join(dir, OUT_FIXTURE_BASENAME)
  end

  def generate_out!(domain_dir, out_dir)
    _out, err, status = ProjectDeployRunner.run(domain_dir, "--out=#{out_dir}", root: root)
    status.success? or raise "hecks deploy project out= failed: #{err}"
  end

  # Yields a throwaway domain, the directory to write its recipe to, and the place in this
  # repo's deploy/ a recipe would land if `out=` were ignored.
  def with_recipe_out
    Dir.mktmpdir do |dir|
      in_repo = File.join(root, "deploy", OUT_FIXTURE_BASENAME)
      FileUtils.rm_rf(in_repo)

      begin
        yield write_fixture(dir), File.join(dir, "client", "deploy-aws", "domain"), in_repo
      ensure
        FileUtils.rm_rf(in_repo)
      end
    end
  end

  it "writes the recipe to --out", :aggregate_failures do
    with_recipe_out do |domain_dir, out_dir, _in_repo|
      generate_out!(domain_dir, out_dir)

      expect(File).to exist(File.join(out_dir, "template.yaml"))
      expect(File).to exist(File.join(out_dir, "Makefile"))
    end
  end

  it "writes nothing into this repo's deploy/" do
    with_recipe_out do |domain_dir, out_dir, in_repo|
      generate_out!(domain_dir, out_dir)

      expect(File).not_to exist(in_repo)
    end
  end
end
