require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "json"

# `hecks deploy project` for a domain that declares `deployed_to("Vercel")`: the domain's host as
# one Vercel function. The promises: the defaults render a working `vercel.json`, a full world
# renders its crons and variables, and a world cannot splice shell or JSON into the output.
RSpec.describe "hecks deploy project — a deployed_to(\"Vercel\") function", :io do
  VERCEL_ROOT_DIR = File.expand_path("..", __dir__)
  VERCEL_FIXTURE = "scratch_fixture".freeze

  VERCEL_BLUEBOOK = <<~BLUEBOOK.freeze
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

  def world_source(*lines)
    body = lines.map { |line| "    #{line}\n" }.join
    "Hecks.world \"Scratch\" do\n  deployed_to(\"Vercel\") do\n#{body}  end\nend\n"
  end

  # Writes the scratch domain with the world into `dir`; returns the domain directory.
  def write_domain(dir, world_body)
    bluebook_dir = File.join(dir, VERCEL_FIXTURE, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "#{VERCEL_FIXTURE}.bluebook"), VERCEL_BLUEBOOK)
    File.write(File.join(bluebook_dir, "#{VERCEL_FIXTURE}.world"), world_body)
    File.dirname(bluebook_dir)
  end

  # @return [Array(Hash{String => String}, String)] the generated files (nil on a refusal) and stderr
  def generate(world_body)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(write_domain(dir, world_body), "--out=#{out}",
                                                        root: VERCEL_ROOT_DIR)
      return [nil, stderr] unless status.success?

      [Dir.children(out).to_h { |name| [name, File.read(File.join(out, name))] }, stderr]
    end
  end

  context "with a world that sets nothing" do
    let(:files) { generate(world_source).first }
    let(:config) { JSON.parse(files["vercel.json"]) }

    it "writes the four files" do
      expect(files.keys).to match_array(%w[vercel.json .vercelignore deploy-vercel.sh Makefile])
    end

    it "sizes the function and sends every path to it", :aggregate_failures do
      expect(config["functions"]).to eq("api/host.rs" => { "memory" => 1024, "maxDuration" => 30 })
      expect(config["rewrites"]).to eq([{ "source" => "/(.*)", "destination" => "/api/host" }])
      expect(config["regions"]).to eq(["iad1"])
    end

    it "declares no crons and requires DATABASE_URL from the environment", :aggregate_failures do
      expect(config).not_to have_key("crons")
      expect(files["deploy-vercel.sh"]).to include("DATABASE_URL:?DATABASE_URL must be set")
    end
  end

  context "with a full world" do
    let(:lines) do
      ['region "fra1"', "memory 2048", "max_duration 60", 'scope "acme"', 'env ["SESSION_SECRET"]',
       'crons [{ path: "/cron/tick", schedule: "*/5 * * * *" }]']
    end
    let(:files) { generate(world_source(*lines)).first }
    let(:config) { JSON.parse(files["vercel.json"]) }

    it "renders the region, sizes and crons", :aggregate_failures do
      expect(config["regions"]).to eq(["fra1"])
      expect(config["functions"]["api/host.rs"]).to eq("memory" => 2048, "maxDuration" => 60)
      expect(config["crons"]).to eq([{ "path" => "/cron/tick", "schedule" => "*/5 * * * *" }])
    end

    it "names the variable and the team, and never assigns a value", :aggregate_failures do
      expect(files["deploy-vercel.sh"]).to include("SESSION_SECRET", "--scope acme")
      expect(files["deploy-vercel.sh"]).not_to match(/\bSESSION_SECRET=/)
    end
  end

  # The paths written under the output directory, for a world generated with the flags.
  def written(world_body, *flags)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      ProjectDeployRunner.run(write_domain(dir, world_body), "--out=#{out}", *flags, root: VERCEL_ROOT_DIR)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: out).select { |path| File.file?(File.join(out, path)) }
    end
  end

  context "with Vercel and AwsBox both declared" do
    let(:world) do
      <<~WORLD
        Hecks.world "Scratch" do
          deployed_to("AwsBox") do
            region "us-east-1"
            containers [{ name: "web", port: 8080 }]
          end
          deployed_to("Vercel") do
            region "iad1"
          end
        end
      WORLD
    end

    it "writes each kind under its own directory, so neither Makefile is lost", :aggregate_failures do
      paths = written(world)

      expect(paths).to include("vercel/vercel.json", "vercel/Makefile", "awsbox/box.yaml", "awsbox/Makefile")
      expect(paths).not_to include("Makefile")
    end

    it "writes only the named kind, straight into the output directory with --target" do
      expect(written(world, "--target=Vercel")).to match_array(%w[vercel.json .vercelignore deploy-vercel.sh Makefile])
    end
  end

  {
    'region "us-east-1"' => /region is a Vercel id/,
    "memory 64" => /memory is at least 128 MB/,
    "max_duration 900" => /duration is at most 800 seconds/,
    'env ["x; rm -rf /"]' => /env .* is not allowed/,
    'crons [{ path: "/a", schedule: "* *" }]' => /cron_schedule .* is not allowed/
  }.each do |line, message|
    it "refuses #{line}" do
      files, stderr = generate(world_source(line))

      expect([files, stderr]).to match([nil, message])
    end
  end
end
