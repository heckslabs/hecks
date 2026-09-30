require "hecks"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/hecks/hecks/adapters/rust_workspace"

# Both checks below walk the same glob-derived sources `Hecks::Framework.members`
# and `hecks.gemspec` already use, so a new framework member is covered without
# adding it to a list here.
RSpec.describe "gem packaging" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "hecks.gemspec")) }

  it "packages every file `Hecks::Framework.members` finds" do
    packaged = gemspec.files.to_set

    missing = Hecks::Framework.members.values.reject do |path|
      packaged.include?(Pathname.new(path).relative_path_from(root).to_s)
    end

    message = "not in the packaged gem: #{missing.join(', ')} — a symlink pointing outside lib/ " \
              "never survives `gem build` (RubyGems drops it silently); the real content has to " \
              "live inside lib/ itself"
    expect(missing).to be_empty, message
  end

  # A scratch tree holding the gemspec and its version file, with the given files written into it.
  def gemspec_in(dir, files)
    FileUtils.mkdir_p(File.join(dir, "lib/hecks"))
    FileUtils.cp(File.join(root, "hecks.gemspec"), dir)
    File.write(File.join(dir, "lib/hecks/version.rb"), "module Hecks\n  VERSION = \"0.0.0\" unless defined?(VERSION)\nend\n")
    files.each do |file, text|
      FileUtils.mkdir_p(File.join(dir, File.dirname(file)))
      File.write(File.join(dir, file), text)
    end
    yield if block_given?
    Gem::Specification.load(File.join(dir, "hecks.gemspec"))
  end

  it "ships only tracked files in a git checkout, so untracked and gitignored files stay out" do
    Dir.mktmpdir("gemspec-git") do |tmp|
      dir = File.realpath(tmp)
      spec = gemspec_in(dir, ".gitignore" => "lib/ignored.rb\n", "lib/tracked.rb" => "", "exe/hecks" => "",
                             "qa/settings.yml" => "", "lib/untracked.rb" => "", "lib/ignored.rb" => "") do
        Dir.chdir(dir) do
          system("git", "init", "-q", exception: true)
          system("git", "add", ".gitignore", "lib/hecks/version.rb", "lib/tracked.rb", "exe/hecks", "qa/settings.yml",
                 exception: true)
        end
      end

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

  it "leaves out every crate's own tests/, which only the corpus needs" do
    Dir.mktmpdir("gemspec-tests") do |tmp|
      spec = gemspec_in(File.realpath(tmp), "rust/host/tests/fixtures/a.rb" => "", "rust/parser/tests/b.rs" => "",
                                            "rust/tests/c.rs" => "", "rust/host/src/lib.rs" => "")

      expect(spec.files).to include("rust/host/src/lib.rs")
      expect(spec.files.grep(%r{\Arust/(.+/)?tests/})).to be_empty
    end
  end

  it "carries no symlink under lib/ — one pointing outside it is silently dropped by `gem build`" do
    symlinked = Dir.glob(File.join(root, "lib/**/*"), File::FNM_DOTMATCH).select { |path| File.symlink?(path) }
    names = symlinked.map { |path| Pathname.new(path).relative_path_from(root) }

    message = "symlink(s) under lib/: #{names.join(', ')} — RubyGems warns and drops these from the " \
              "packaged gem regardless of where they point; the real content has to be a real file " \
              "inside lib/, with any symlink pointing the other way, from outside lib/ back in"
    expect(symlinked).to be_empty, message
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

    it "ships exe/hecks, executable, as the gem's one command" do
      expect(gemspec.files).to include("exe/hecks")
      expect(gemspec.bindir).to eq("exe")
      expect(gemspec.executables).to eq(["hecks"])
      expect(File.executable?(File.join(root, "exe/hecks"))).to be(true)
    end

    it "ships qa/settings.yml, the dials the Hecks chapter reads when it boots" do
      expect(gemspec.files).to include("qa/settings.yml")
    end

    it "ships the tooling the commands load on demand" do
      missing = tooling.reject { |path| File.exist?(File.join(root, path)) }
      expect(missing).to be_empty, "named here but gone from the repository: #{missing.join(', ')}"

      unshipped = tooling.reject { |path| gemspec.files.any? { |file| file == path || file.start_with?(path) } }
      expect(unshipped).to be_empty, "tooling missing from the packaged gem: #{unshipped.join(', ')}"
    end

    it "loads none of the tooling from `require \"hecks\"`" do
      script = <<~RUBY
        require "hecks"
        puts $LOADED_FEATURES.grep(%r{/lib/hecks/}).map { |f| f.sub(%r{\\A.*?/lib/}, "lib/") }
      RUBY
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3("ruby", "-I", File.join(root, "lib"), "-e", script, chdir: root)
      end
      expect(status).to be_success, err

      loaded = out.lines.map(&:chomp).select(&in_tooling)
      expect(loaded).to be_empty, "lib/hecks.rb loads tooling: #{loaded.join(', ')}"
    end

    describe "the Rust workspace" do
      let(:rust) { gemspec.files.select { |file| file.start_with?("rust/") } }

      it "ships the kernel and every crate a domain build uses" do
        expected = %w[rust/Cargo.toml rust/Cargo.lock rust/project.rb rust/project_rust_pipeline.rb
                      rust/src/lib.rs rust/src/main.rs rust/codegen/Cargo.toml rust/parser/Cargo.toml
                      rust/host/Cargo.toml rust/build/Cargo.toml rust/web/Cargo.toml rust/lsp/Cargo.toml]
        expect(rust).to include(*expected)
        expect(rust.grep(%r{\Arust/src/kernel/})).not_to be_empty
      end

      it "ships no build output, no corpus tests and no generated corpus domain" do
        stray = rust.grep(%r{\Arust/(tests/|[^/]+/tests/|src/generated/)|(\A|/)target/})
        expect(stray).to be_empty, "in the packaged gem: #{stray.first(5).join(', ')}"
        expect(Dir.exist?(File.join(root, "rust/src/generated"))).to be(true), "the corpus's generated modules moved"
      end

      it "gives a build a workspace with no corpus domain in it and a clean Cargo feature list", :io do
        Dir.mktmpdir("hecks-package") do |tmp|
          installed = File.join(File.realpath(tmp), "gem")
          gemspec.files.each do |file|
            FileUtils.mkdir_p(File.join(installed, File.dirname(file)))
            FileUtils.cp(File.join(root, file), File.join(installed, file), preserve: true)
          end
          app = File.join(File.realpath(tmp), "app")
          space = Hecks::Adapters::RustWorkspace.new(gem_root: installed, project_root: app, version: "9.9.9")

          expect(space).not_to be_checkout
          copy = space.directory

          expect(copy).to eq(File.join(app, ".hecks", "rust", "9.9.9"))
          expect(File.exist?(File.join(copy, "src/lib.rs"))).to be(true)
          expect(File.exist?(File.join(copy, "project.rb"))).to be(true)
          expect(Dir.exist?(File.join(copy, "src/generated"))).to be(false)
          expect(File.read(File.join(copy, "Cargo.toml"))).to include("[features]\ndefault = []\n")
          expect(File.read(File.join(copy, "Cargo.toml"))).not_to match(/^pizzas = /)
          expect(Dir.glob(File.join(installed, "rust/**/target"))).to be_empty
          expect(Dir.exist?(File.join(installed, "rust/src/generated"))).to be(false)
        end
      end
    end

    # Copies only the packaged files into a scratch dir and loads them there
    # without Bundler, so a require the package omits fails as a LoadError
    # instead of quietly succeeding via this repo's own lib/ on $LOAD_PATH.
    it "loads the framework and every subcommand from the packaged files alone", :io do
      Dir.mktmpdir("hecks-package") do |tmp|
        dir = File.realpath(tmp)
        gemspec.files.each do |file|
          FileUtils.mkdir_p(File.join(dir, File.dirname(file)))
          FileUtils.cp(File.join(root, file), File.join(dir, file), preserve: true)
        end

        commands = ["run", "document", "ir", "stores", "model_check", "smoke_test", "project_diagrams",
                    "project_cli", "mcp", "mcp_door"]
        script = <<~RUBY
          require "hecks"
          #{commands.map { |name| "require \"hecks/cli/#{name}\"" }.join("\n")}
          stray = $LOADED_FEATURES.grep(%r{/lib/hecks(\\.rb|/)}).reject { |f| f.start_with?(#{dir.inspect}) }
          abort "loaded from outside the package: \#{stray.join(', ')}" unless stray.empty?
          puts "loaded"
        RUBY

        run = ->(*argv) { Bundler.with_unbundled_env { Open3.capture3("ruby", *argv, chdir: dir) } }
        out, err, status = run.call("-I", File.join(dir, "lib"), "-e", script)
        expect(status).to be_success, "the packaged files do not load on their own:\n#{err}"
        expect(out).to eq("loaded\n")

        out, err, status = run.call(File.join(dir, "exe/hecks"), "--help")
        expect(status).to be_success, err
        expect(out).to include("hecks <verb> [name=value")
      end
    end
  end
end
