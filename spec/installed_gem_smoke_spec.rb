require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# The gem as a client gets it: built from hecks.gemspec, installed into a scratch GEM_HOME, and
# its `hecks` executable run from a directory that is not a hecks checkout, on a copy of
# examples/banking. Nothing here reads `lib/` from the working tree, so a file the gemspec
# leaves out, or a `require` that reaches outside the gem, fails here and nowhere else.
#
# Tagged :io so the default run skips it: it builds a gem and boots the Hecks chapter once per
# command. Run it with `bundle exec ruby run_specs.rb spec/installed_gem_smoke_spec.rb`.
RSpec.describe "the installed hecks gem", :io do
  before(:all) do
    root = File.expand_path("..", __dir__)
    @work = Dir.mktmpdir("hecks-gem-smoke")
    @home = File.join(@work, "gems")
    built = File.join(@work, "hecks.gem")
    out, status = Open3.capture2e("gem", "build", "hecks.gemspec", "--output", built, chdir: root)
    raise "gem build failed:\n#{out}" unless status.success?

    # prism is the gem's one dependency and is already installed; the smoke checks the gem's own
    # files, not RubyGems' resolver, so no network is needed.
    env = { "GEM_HOME" => @home, "GEM_PATH" => Gem.path.unshift(@home).uniq.join(":") }
    out, status = Bundler.with_unbundled_env do
      Open3.capture2e(env, "gem", "install", "--local", "--ignore-dependencies", "--no-document", built)
    end
    raise "gem install failed:\n#{out}" unless status.success?

    @project = File.join(@work, "project")
    FileUtils.mkdir_p(@project)
    FileUtils.cp_r(File.join(root, "examples/banking/."), @project)
    @env = env.merge("HECKS_ENVIRONMENT" => "memory", "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8")
  end

  after(:all) { FileUtils.remove_entry(@work) if @work && File.directory?(@work) }

  # Runs the installed `hecks` from the sample project.
  #
  # @return [Array(String, String, Integer)] stdout, stderr, exit status
  def hecks(*args)
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(@env, RbConfig.ruby, File.join(@home, "bin/hecks"), *args, chdir: @project)
    end
    [out, err, status.exitstatus]
  end

  it "runs from a directory that is not a hecks checkout" do
    expect(File.exist?(File.join(@project, "hecks.gemspec"))).to be(false)
    expect(Dir.glob(File.join(@home, "gems/hecks-*/hecks.gemspec"))).to be_empty
  end

  it "lists its commands for --help" do
    out, err, code = hecks("--help")

    expect(code).to eq(0), err
    expect(out).to include("hecks <command>!", "  build:\n", "build_wasm!", "  regeneration_run:\n", "regenerate_corpus!")
  end

  it "prints a domain's IR as JSON for `ir`" do
    out, err, code = hecks("ir", ".")

    expect(code).to eq(0), err
    expect(JSON.parse(out)).to have_key("Banking")
  end

  it "prints a domain's stores as JSON for `stores`" do
    out, err, code = hecks("stores", ".")

    expect(code).to eq(0), err
    expect(JSON.parse(out)).to have_key("customer")
  end

  it "answers `stores` without a domain with a usage line, not a backtrace" do
    _out, err, code = hecks("stores")

    expect(code).not_to eq(0)
    expect(err).to include("usage:")
    expect(err).not_to include("IndexError")
  end

  it "refuses `build_wasm` without its arguments by name" do
    _out, err, code = hecks("build.build_wasm")

    expect(code).to eq(1)
    expect(err).to include("BuildWasm was not given domain")
  end

  it "answers `build_wasm --help` with the command's shape" do
    out, err, code = hecks("build.build_wasm", "--help")

    expect(code).to eq(0), err
    expect(out).to include("dispatches Hecks::Build.BuildWasm", "domain.value")
  end

  it "reaches the wasm toolchain for `build_wasm`, and reports a missing target as a refusal" do
    out, err, code = hecks("build.build_wasm", "domain.value=#{@project}/", "run.value=smoke", "--wait")
    # The launcher prints the record on stdout whether the build ended or faulted; the failure
    # state goes to stderr, after it.
    record = JSON.parse(out[/^\{.*?^\}$/m] || raise("no record on stdout (exit #{code}):\n#{out}\n#{err}"))

    expect(record.fetch("events")).to include("WasmBuildRequested")
    if code.zero?
      expect(record.dig("state", "status")).not_to eq("faulted")
    else
      expect(record.dig("state", "refusal", "value")).to match(/wasm32-wasip1|cargo|rustup/)
    end
  end

  it "refuses a Codebase command with 'needs a hecks checkout'" do
    out, err, code = hecks("regeneration_run.regenerate_corpus")

    expect(code).to eq(0), err
    expect(JSON.parse(out).fetch("refused_reactions").map { |r| r.fetch("reason") })
      .to include(a_string_including("needs a hecks checkout"))
  end
end
