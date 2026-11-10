require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# The gate on examples that reach a live service, read from a real test-runner child on a spec
# file of one plain and one `:cloudfront` example: what a verification's batch selects with the
# `--example " "` filter every launcher run passes, which clears RSpec's tag exclusions.
RSpec.describe LiveServices do
  let(:dir) { Dir.mktmpdir("live-services") }

  after { FileUtils.rm_rf(dir) }

  def spec_file
    support = File.join(described_class::ROOT, "spec/support/live_services")
    File.join(dir, "gate_spec.rb").tap do |path|
      File.write(path, <<~RUBY)
        require #{support.inspect}
        RSpec.configure { |config| LiveServices.install(config) }
        RSpec.describe("gate") { it("plain") {}; it("live", :cloudfront) {} }
      RUBY
    end
  end

  def selected(*filters, opt_in: nil)
    argv = [RbConfig.ruby, "-I", File.join(described_class::ROOT, "lib"), "-e",
            "require 'rspec/core'; exit RSpec::Core::Runner.run(ARGV)", "--", *filters, spec_file]
    out, = Open3.capture2e({ described_class::VARIABLE => opt_in }, *argv, chdir: dir)
    out[/(\d+) examples?/, 1].to_i
  end

  it "selects no live example under the full-description filter a verification passes" do
    expect(selected("--example", " ")).to eq(1)
  end

  it "selects no live example when only the tag asks for it" do
    expect(selected("--tag", "cloudfront")).to eq(0)
  end

  it "selects the live example when the run opts in by the variable and the tag" do
    expect(selected("--tag", "cloudfront", opt_in: "cloudfront")).to eq(1)
  end

  it "gates the world's tags, and cloudfront even where no world can be read", :aggregate_failures do
    expect(described_class.tags).to include("cloudfront")
    expect(described_class.tags(dir)).to eq(described_class::ALWAYS)
  end

  it "judges AWS credentials from the environment and files, with no call" do
    expect(described_class.aws_credentials?({}, dir)).to be(false)
  end

  it "takes a named profile as credentials" do
    expect(described_class.aws_credentials?({ "AWS_PROFILE" => "dev" }, dir)).to be(true)
  end
end
