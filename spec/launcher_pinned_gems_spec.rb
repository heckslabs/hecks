require "spec_helper"
require "tmpdir"
require "hecks/tools/project_cli"

# A checkout's launcher runs on the gems its Gemfile pins, the set `bundle exec` and CI use. The
# block that does it is run here in scratch roots, so no launcher has to boot to test the decision.
RSpec.describe "the launcher's pinned gems" do
  let(:root) { Dir.mktmpdir("hecks-pinned") }
  let(:json_pin) { File.read(File.expand_path("../Gemfile", __dir__))[/gem "json", "([\d.]+)"/, 1] }
  # What a process started by a launcher that already took the pin would inherit, unset.
  let(:clean_env) { ENV.keys.grep(/\A(BUNDLE|BUNDLER|RUBYOPT|RUBYLIB)/).to_h { |name| [name, nil] } }

  after { FileUtils.remove_entry(root) }

  def pinned_block = Hecks::Tools::ProjectCli.render(Hecks::Tools::ProjectCli::Templates::PINNED_GEMS, up: "../")

  def ruby_output(*args) = IO.popen(clean_env, ["ruby", *args], err: File::NULL, &:read)

  # Runs the block from `exe/` of the scratch root and prints the json version the process then
  # holds, and whether Bundler is loaded.
  def run_block
    FileUtils.mkdir_p(File.join(root, "exe"))
    script = File.join(root, "exe/launch.rb")
    File.write(script, "#{pinned_block}\nrequire \"json\"\nprint JSON::VERSION, \" \", !!defined?(Bundler)\n")
    ruby_output(script)
  end

  def gemfile_pinning(version) = %(source "https://rubygems.org"\ngem "json", "#{version}"\n)

  def add_checkout_files(gemfile)
    File.write(File.join(root, "hecks.gemspec"), "")
    File.write(File.join(root, "Gemfile"), gemfile)
  end

  it "takes the pinned gem in a checkout whose Gemfile pins one" do
    add_checkout_files(gemfile_pinning(json_pin))

    expect(run_block).to eq("#{json_pin} true")
  end

  it "leaves the gems at hand beside an installed gem, where no gemspec stands next to the Gemfile" do
    File.write(File.join(root, "Gemfile"), gemfile_pinning(json_pin))

    expect(run_block).to end_with(" false")
  end

  it "leaves the gems at hand when the pinned set is not installed" do
    add_checkout_files(gemfile_pinning("0.0.1"))

    expect(run_block).to start_with(ruby_output("-rjson", "-e", "print JSON::VERSION"))
  end

  it "is the block exe/hecks carries, so the committed launcher takes the pin" do
    expect(File.read(File.expand_path("../exe/hecks", __dir__))).to include(pinned_block)
  end

  # A launcher beside a client's domain runs on what the client's own Gemfile pins, such as a
  # local Hecks it is built alongside; with no Gemfile it runs on the gems at hand.
  describe "beside a client's domain" do
    def project_block = Hecks::Tools::ProjectCli.render(Hecks::Tools::ProjectCli::Templates::PROJECT_GEMS, up: "../")

    def run_project_block
      FileUtils.mkdir_p(File.join(root, "bluebook"))
      script = File.join(root, "bluebook/launch.rb")
      File.write(script, "#{project_block}\nrequire \"json\"\nprint JSON::VERSION, \" \", !!defined?(Bundler)\n")
      ruby_output(script)
    end

    it "takes the gems the project's Gemfile pins" do
      File.write(File.join(root, "Gemfile"), gemfile_pinning(json_pin))

      expect(run_project_block).to eq("#{json_pin} true")
    end

    it "leaves the gems at hand where the project has no Gemfile" do
      expect(run_project_block).to end_with(" false")
    end
  end
end
