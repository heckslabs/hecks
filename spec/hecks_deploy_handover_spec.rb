require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# `hecks deploy handover.clear` end to end: the Deploy chapter's Handover asks the DeployToolchain
# port, the Hecks domain binds its adapter, and a throwaway domain's `.world` files are emptied of
# their `deployed_to` settings and still load.
RSpec.describe "the Deploy chapter's Handover", :io do
  WORLD_TO_CLEAR = <<~RUBY.freeze
    Hecks.world "Shop" do
      realm "Shop"

      deployed_to("AwsBox") do
        region "us-east-1"
        public_url "https://shop.example.com"
      end
    end
  RUBY

  FAULT_PREFIX = "Hecks::Adapters::ConsoleCapture::Failure: ".freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def with_domain(files = { "bluebook/shop.world" => WORLD_TO_CLEAR })
    Dir.mktmpdir do |dir|
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "domain", path)))
        File.write(File.join(dir, "domain", path), text)
      end
      yield File.join(dir, "domain"), dir
    end
  end

  def world_names(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(file) }
    registry.worlds.keys
  end

  def clear(domain, *argv)
    out, status = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", "handover.clear", domain, *argv, "--wait"])
    [JSON.parse(out), status]
  end

  it "declares the clearing and its recorders in the Deploy chapter" do
    commands = @hecks.registry.bluebook("Deploy").aggregate("Handover").commands.map(&:hecks_name)

    expect(commands).to eq(%w[Clear Complete Fault])
  end

  it "clears a domain's world in place and records it as cleared" do
    with_domain do |domain|
      json, status = clear(domain)

      expect([status, json.dig("state", "status")]).to eq([0, "cleared"])
    end
  end

  it "names the file and the settings removed" do
    with_domain do |domain|
      json, = clear(domain)

      expect(json.dig("state", "output", "value")).to include("shop.world: cleared region, public_url")
    end
  end

  it "leaves no deployment value in the world" do
    with_domain do |domain|
      clear(domain)

      expect(File.read(File.join(domain, "bluebook/shop.world"))).not_to include("us-east-1")
    end
  end

  it "leaves a world that still loads" do
    with_domain do |domain|
      clear(domain)

      expect(world_names(File.join(domain, "bluebook/shop.world"))).to eq(["Shop"])
    end
  end

  it "writes the cleared copy to out and leaves the original" do
    with_domain do |domain, dir|
      clear(domain, "out=#{File.join(dir, "handed")}")

      expect(File.read(File.join(domain, "bluebook/shop.world"))).to eq(WORLD_TO_CLEAR)
    end
  end

  it "puts the cleared copy at its path below bluebook" do
    with_domain do |domain, dir|
      clear(domain, "out=#{File.join(dir, "handed")}")

      expect(File.read(File.join(dir, "handed/shop.world"))).not_to include("us-east-1")
    end
  end

  it "clears the environment overlays too" do
    with_domain("bluebook/shop.world" => WORLD_TO_CLEAR, "bluebook/environments/production.world" => WORLD_TO_CLEAR) do |domain|
      clear(domain)

      expect(File.read(File.join(domain, "bluebook/environments/production.world"))).not_to include("us-east-1")
    end
  end

  it "says so when there is nothing to clear" do
    with_domain("bluebook/shop.world" => "Hecks.world(\"Shop\") do\nend\n") do |domain|
      json, = clear(domain)

      expect(json.dig("state", "output", "value")).to eq("no deployed_to settings to clear")
    end
  end

  it "faults a domain with no world file, with the sentence saying so" do
    with_domain("bluebook/shop.bluebook" => "") do |domain|
      json, status = clear(domain)

      sentence = "#{FAULT_PREFIX}#{domain}/bluebook holds no .world file to clear"

      expect([status, json.dig("state", "refusal", "value")]).to eq([1, sentence])
    end
  end
end
