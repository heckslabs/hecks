require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# `smoke true` in a domain's `deployed_to` block adds the smoke harness and workflow
# to what `hecks deploy project` writes, and nothing else changes. Runs the generator in this
# process, like spec/project_deploy_fargate_spec.rb.
RSpec.describe "hecks deploy project — smoke true", :io do
  SMOKE_DEPLOY_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Scratch" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  BLUEBOOK

  def world(smoke_lines)
    <<~WORLD
      Hecks.world "Scratch" do
        deployed_to("AwsFargate") do
          region "us-east-1"
          cpu 256
          memory 512
          port 8080
      #{smoke_lines.gsub(/^/, "    ")}
        end
      end
    WORLD
  end

  # Runs the script once per world body against one scratch domain, since the generated
  # files name the domain's path, and answers each run's result: { relative path =>
  # contents }, or the stderr of a run that failed.
  def generate(*world_bodies)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, "scratch_smoke_domain")
      FileUtils.mkdir_p(File.join(domain, "bluebook"))
      File.write(File.join(domain, "bluebook", "scratch_smoke_domain.bluebook"), SMOKE_DEPLOY_BLUEBOOK)

      world_bodies.each_with_index.map do |body, index|
        File.write(File.join(domain, "bluebook", "scratch_smoke_domain.world"), body)
        generate_into(domain, File.join(dir, "out#{index}"))
      end
    end
  end

  def generate_into(domain, out)
    _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: InMemoryDomain::ROOT)
    return stderr unless status.success?

    Dir.glob("**/*", base: out).select { |path| File.file?(File.join(out, path)) }
       .to_h { |path| [path, File.read(File.join(out, path))] }
  end

  let(:smoke_settings) do
    <<~SETTINGS
      smoke true
      smoke_role_arn "arn:aws:iam::123456789012:role/example-smoke"
      smoke_secret_id "example-stack/session-secret"
      smoke_site_url "https://example.org"
    SETTINGS
  end

  it "adds only the smoke files, leaving every other generated file byte-identical", :aggregate_failures do
    without, with = generate(world(""), world(smoke_settings))

    expect(with.keys - without.keys).to contain_exactly("smoke/harness.js", "smoke/workflow.yml")
    expect(with.reject { |path, _| path.start_with?("smoke/") }).to eq(without)
  end

  it "writes the smoke workflow with the stack's own name and region" do
    with, = generate(world(smoke_settings))

    expect(with["smoke/workflow.yml"]).to include("aws-region: 'us-east-1'")
      .and include("name: 'scratch_smoke_domain smoke test'")
  end

  it "refuses a smoke declaration missing what the workflow needs" do
    stderr, = generate(world("smoke true"))

    expect(stderr).to include("smoke true needs smoke_role_arn, smoke_secret_id, smoke_site_url")
  end
end
