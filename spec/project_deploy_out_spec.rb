require "tmpdir"
require "fileutils"
require "open3"

# `bin/project_deploy --out=<dir>` writes a domain's recipe beside the
# client that owns it instead of into this repo's deploy/. Structural,
# like project_deploy_tenant_spec.rb: runs the script as a subprocess
# against a throwaway domain and reads back what it wrote.
RSpec.describe "bin/project_deploy --out", :io do
  OUT_FIXTURE_BASENAME = "project_deploy_out_spec_fixture".freeze

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, OUT_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)

    File.write(File.join(bluebook_dir, "#{OUT_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

    File.write(File.join(bluebook_dir, "#{OUT_FIXTURE_BASENAME}.world"), <<~WORLD)
      Hecks.world "OutDeploy" do
        deployed_to("AwsLambda") do
          region "us-east-1"
        end
      end
    WORLD

    File.join(dir, OUT_FIXTURE_BASENAME)
  end

  it "writes the recipe to --out and nothing into this repo's deploy/" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)
      out_dir = File.join(dir, "client", "deploy-aws", "domain")
      in_repo = File.join(root, "deploy", OUT_FIXTURE_BASENAME)
      FileUtils.rm_rf(in_repo)

      begin
        _out, err, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir, "--out=#{out_dir}")
        status.success? or raise "bin/project_deploy --out failed: #{err}"

        expect(File).to exist(File.join(out_dir, "template.yaml"))
        expect(File).to exist(File.join(out_dir, "Makefile"))
        expect(File).not_to exist(in_repo)
      ensure
        FileUtils.rm_rf(in_repo)
      end
    end
  end
end
