require "hecks"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/cli/console"
require_relative "../lib/hecks/hecks/adapters/rust_workspace"

# Both checks below walk the same glob-derived sources `Hecks::Framework.members`
# and `hecks.gemspec` already use, so a new framework member is covered without
# adding it to a list here.
RSpec.describe "gem packaging" do
  # What a symlink under lib/ costs the packaged gem, said once for both checks that name one.
  SYMLINK_NOTE = "RubyGems drops a symlink from the packaged gem silently, wherever it points; the real " \
                 "content has to live inside lib/ itself, with any symlink pointing the other way, from " \
                 "outside lib/ back in".freeze

  # The files a scratch checkout holds for the git-tracking check: two tracked, two not.
  CHECKOUT_FILES = {
    ".gitignore"       => "lib/ignored.rb\n",
    "lib/tracked.rb"   => "",
    "exe/hecks"        => "",
    "qa/settings.yml"  => "",
    "lib/untracked.rb" => "",
    "lib/ignored.rb"   => ""
  }.freeze

  CRATE_TEST_FILES = {
    "rust/host/tests/fixtures/a.rb" => "", "rust/parser/tests/b.rs" => "", "rust/tests/c.rs" => "",
    "rust/host/src/lib.rs"          => ""
  }.freeze

  PACKAGED_SUBCOMMANDS = ["run", "document", "ir", "stores", "model_check", "smoke_test", "project_diagrams",
                          "project_cli", "mcp"].freeze

  LOAD_ONLY_HECKS = <<~RUBY.freeze
    require "hecks"
    puts $LOADED_FEATURES.grep(%r{/lib/hecks/}).map { |f| f.sub(%r{\\A.*?/lib/}, "lib/") }
  RUBY

  let(:root) { File.expand_path("..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "hecks.gemspec")) }

  def relative_to_root(path) = Pathname.new(path).relative_path_from(root).to_s

  it "packages every file `Hecks::Framework.members` finds" do
    packaged = gemspec.files.to_set
    missing = Hecks::Framework.members.values.reject { |path| packaged.include?(relative_to_root(path)) }

    expect(missing).to be_empty, "not in the packaged gem: #{missing.join(", ")} — a symlink pointing outside lib/ " \
                                 "never survives `gem build`; #{SYMLINK_NOTE}"
  end

  def with_scratch_dir(prefix) = Dir.mktmpdir(prefix) { |tmp| yield File.realpath(tmp) }

  def write_scratch_file(dir, file, text)
    FileUtils.mkdir_p(File.join(dir, File.dirname(file)))
    File.write(File.join(dir, file), text)
  end

  # A scratch tree holding the gemspec and its version file, with the given files written into it.
  def gemspec_in(dir, files)
    FileUtils.cp(File.join(root, "hecks.gemspec"), dir)
    write_scratch_file(dir, "lib/hecks/version.rb", "module Hecks\n  VERSION = \"0.0.0\" unless defined?(VERSION)\nend\n")
    files.each { |file, text| write_scratch_file(dir, file, text) }
    yield if block_given?
    Gem::Specification.load(File.join(dir, "hecks.gemspec"))
  end

  def track_in_git(dir)
    Dir.chdir(dir) do
      system("git", "init", "-q", exception: true)
      system("git", "add", ".gitignore", "lib/hecks/version.rb", "lib/tracked.rb", "exe/hecks", "qa/settings.yml",
             exception: true)
    end
  end

  it "ships only tracked files in a git checkout, so untracked and gitignored files stay out", :aggregate_failures do
    with_scratch_dir("gemspec-git") do |dir|
      spec = gemspec_in(dir, CHECKOUT_FILES) { track_in_git(dir) }

      expect(spec.files).to include("lib/tracked.rb", "lib/hecks/version.rb", "exe/hecks")
      expect(spec.files).not_to include("lib/untracked.rb", "lib/ignored.rb")
    end
  end

  it "falls back to globbing when there is no git checkout" do
    Dir.mktmpdir("gemspec-plain") do |tmp|
      spec = gemspec_in(File.realpath(tmp), "lib/plain.rb" => "", "exe/hecks" => "", "qa/settings.yml" => "")

      expect(spec.files).to include("lib/plain.rb", "exe/hecks", "qa/settings.yml")
    end
  end

  it "leaves out every crate's own tests/, which only the corpus needs", :aggregate_failures do
    Dir.mktmpdir("gemspec-tests") do |tmp|
      spec = gemspec_in(File.realpath(tmp), CRATE_TEST_FILES)

      expect(spec.files).to include("rust/host/src/lib.rs")
      expect(spec.files.grep(%r{\Arust/(.+/)?tests/})).to be_empty
    end
  end

  it "carries no symlink under lib/ — one pointing outside it is silently dropped by `gem build`" do
    symlinked = Dir.glob(File.join(root, "lib/**/*"), File::FNM_DOTMATCH).select { |path| File.symlink?(path) }
    names = symlinked.map { |path| relative_to_root(path) }

    expect(symlinked).to be_empty, "symlink(s) under lib/: #{names.join(", ")} — #{SYMLINK_NOTE}"
  end

  # Copies the packaged files into `into`, creating the directories they need.
  def install_gem_files(into)
    gemspec.files.each do |file|
      FileUtils.mkdir_p(File.join(into, File.dirname(file)))
      FileUtils.cp(File.join(root, file), File.join(into, file), preserve: true)
    end
  end

  # Yields a scratch directory holding only the packaged files, and the scratch directory around it.
  def with_installed_gem
    Dir.mktmpdir("hecks-package") do |tmp|
      base = File.realpath(tmp)
      install_gem_files(File.join(base, "gem"))
      yield File.join(base, "gem"), base
    end
  end

  def with_installed_workspace
    with_installed_gem do |installed, base|
      app = File.join(base, "app")
      yield Hecks::Adapters::RustWorkspace.new(gem_root: installed, project_root: app, version: "9.9.9"), installed, app
    end
  end

  def unbundled_ruby(*argv, chdir:) = Bundler.with_unbundled_env { Open3.capture3("ruby", *argv, chdir: chdir) }

  # The program that requires the framework and every packaged subcommand, then names any feature
  # that loaded from outside `dir`.
  def packaged_load_script(dir)
    requires = PACKAGED_SUBCOMMANDS.map { |name| "require \"hecks/cli/#{name}\"" }.join("\n")
    <<~RUBY
      require "hecks"
      #{requires}
      stray = $LOADED_FEATURES.grep(%r{/lib/hecks(\\.rb|/)}).reject { |f| f.start_with?(#{dir.inspect}) }
      abort "loaded from outside the package: \#{stray.join(', ')}" unless stray.empty?
      puts "loaded"
    RUBY
  end

  # ADR 0066: the gem ships one command, `exe/hecks`. The tooling behind the repository's other
  # commands ships with `lib/`, and `lib/hecks.rb` loads none of it until a command asks.
  # Paths here are named by hand, independent of the gemspec's own pattern.
  describe "the `hecks` command and the tooling that ships with it" do
    let(:tooling) do
      ["lib/hecks/fuzzing/", "lib/hecks/fuzzing.rb", "lib/hecks/bench/", "lib/hecks/bench.rb",
       "lib/hecks/corpus.rb", "lib/hecks/codemod.rb", "lib/hecks/query_ir.rb",
       "lib/hecks/grammar/evolve.rb", "lib/hecks/doc/", "lib/hecks/tools/", "lib/hecks/tools.rb"]
    end
    let(:in_tooling) { ->(file) { tooling.any? { |path| file == path || file.start_with?(path) } } }

    it "ships exe/hecks, executable, as the gem's one command", :aggregate_failures do
      expect(gemspec.files).to include("exe/hecks")
      expect(gemspec.bindir).to eq("exe")
      expect(gemspec.executables).to eq(["hecks"])
      expect(File.executable?(File.join(root, "exe/hecks"))).to be(true)
    end

    it "ships qa/settings.yml, the dials the Hecks chapter reads when it boots" do
      expect(gemspec.files).to include("qa/settings.yml")
    end

    it "ships the pizzas example `hecks console` opens when given no domain, and not its glossary", :aggregate_failures do
      opened = Hecks::CLI::Console::DEFAULT_FILES.map { |file| file.delete_prefix("#{root}/") }

      expect(gemspec.files).to include(*opened)
      expect(gemspec.files.grep(%r{\Aexamples/pizzas/glossary/})).to be_empty
      expect(gemspec.files.grep(%r{\Aexamples/}).grep_v(%r{\Aexamples/pizzas/})).to be_empty
    end

    it "ships the tooling the commands load on demand", :aggregate_failures do
      missing = tooling.reject { |path| File.exist?(File.join(root, path)) }
      expect(missing).to be_empty, "named here but gone from the repository: #{missing.join(", ")}"

      unshipped = tooling.reject { |path| gemspec.files.any? { |file| file == path || file.start_with?(path) } }
      expect(unshipped).to be_empty, "tooling missing from the packaged gem: #{unshipped.join(", ")}"
    end

    it "loads none of the tooling from `require \"hecks\"`", :aggregate_failures do
      out, err, status = unbundled_ruby("-I", File.join(root, "lib"), "-e", LOAD_ONLY_HECKS, chdir: root)
      expect(status).to be_success, err

      loaded = out.lines.map(&:chomp).select(&in_tooling)
      expect(loaded).to be_empty, "lib/hecks.rb loads tooling: #{loaded.join(", ")}"
    end

    describe "the Rust workspace" do
      let(:rust) { gemspec.files.select { |file| file.start_with?("rust/") } }

      it "ships the kernel and every crate a domain build uses", :aggregate_failures do
        # `rust/codegen/src/json.rs` is compiled into `hecks-build` by path, so it ships with it.
        expected = %w[rust/Cargo.toml rust/Cargo.lock rust/src/lib.rs rust/src/main.rs
                      rust/codegen/Cargo.toml rust/codegen/src/json.rs rust/parser/Cargo.toml
                      rust/host/Cargo.toml rust/build/Cargo.toml rust/web/Cargo.toml rust/lsp/Cargo.toml]
        expect(rust).to include(*expected)
        expect(rust.grep(%r{\Arust/src/kernel/})).not_to be_empty
      end

      it "ships no build output, no corpus tests and no generated corpus domain", :aggregate_failures do
        stray = rust.grep(%r{\Arust/(tests/|[^/]+/tests/|src/generated/)|(\A|/)target/})
        expect(stray).to be_empty, "in the packaged gem: #{stray.first(5).join(", ")}"
        expect(Dir.exist?(File.join(root, "rust/src/generated"))).to be(true), "the corpus's generated modules moved"
      end

      it "gives a build a workspace under the project, apart from the checkout", :aggregate_failures, :io do
        with_installed_workspace do |space, _installed, app|
          expect(space).not_to be_checkout
          expect(space.directory).to eq(File.join(app, ".hecks", "rust", "9.9.9"))
        end
      end

      it "gives a build the kernel and the codegen crate", :aggregate_failures, :io do
        with_installed_workspace do |space|
          expect(File.exist?(File.join(space.directory, "src/lib.rs"))).to be(true)
          expect(File.exist?(File.join(space.directory, "codegen/Cargo.toml"))).to be(true)
        end
      end

      it "gives a build a workspace with no corpus domain in it", :aggregate_failures, :io do
        with_installed_workspace do |space, installed|
          expect(Dir.exist?(File.join(space.directory, "src/generated"))).to be(false)
          expect(Dir.exist?(File.join(installed, "rust/src/generated"))).to be(false)
          expect(Dir.glob(File.join(installed, "rust/**/target"))).to be_empty
        end
      end

      it "gives a build a clean Cargo feature list", :aggregate_failures, :io do
        with_installed_workspace do |space|
          cargo = File.read(File.join(space.directory, "Cargo.toml"))

          expect(cargo).to include("[features]\ndefault = []\n")
          expect(cargo).not_to match(/^pizzas = /)
        end
      end
    end

    # Copies only the packaged files into a scratch dir and loads them there
    # without Bundler, so a require the package omits fails as a LoadError
    # instead of quietly succeeding via this repo's own lib/ on $LOAD_PATH.
    it "loads the framework and every subcommand from the packaged files alone", :aggregate_failures, :io do
      with_installed_gem do |dir|
        out, err, status = unbundled_ruby("-I", File.join(dir, "lib"), "-e", packaged_load_script(dir), chdir: dir)
        expect(status).to be_success, "the packaged files do not load on their own:\n#{err}"
        expect(out).to eq("loaded\n")
      end
    end

    it "answers --help from the packaged exe/hecks", :aggregate_failures, :io do
      with_installed_gem do |dir|
        out, err, status = unbundled_ruby(File.join(dir, "exe/hecks"), "--help", chdir: dir)
        expect(status).to be_success, err
        expect(out).to include("hecks <command>! [name=value")
      end
    end
  end
end
