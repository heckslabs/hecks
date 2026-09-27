require "hecks"
require "fileutils"
require "open3"
require "tmpdir"

# What 1.5.0 shipped without Compliance at all — nothing here names
# Compliance, or any other framework member, by hand. Both checks below
# walk the SAME glob-derived sources `Hecks::Framework.members` and
# `hecks.gemspec` already use, so a future framework member (or any
# other file added under lib/) is covered automatically; nothing needs
# adding to a list when one is.
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

  it "carries no symlink under lib/ — one pointing outside it is silently dropped by `gem build`" do
    symlinked = Dir.glob(File.join(root, "lib/**/*"), File::FNM_DOTMATCH).select { |path| File.symlink?(path) }
    names = symlinked.map { |path| Pathname.new(path).relative_path_from(root) }

    message = "symlink(s) under lib/: #{names.join(', ')} — RubyGems warns and drops these from the " \
              "packaged gem regardless of where they point; the real content has to be a real file " \
              "inside lib/, with any symlink pointing the other way, from outside lib/ back in"
    expect(symlinked).to be_empty, message
  end

  # ADR 0066: the gem ships a `hecks` command and leaves the repository-only
  # tooling out. Each path here is named by hand, independently of the
  # gemspec's own pattern, so a pattern that stops matching fails here.
  describe "the `hecks` command and the repository-only tooling" do
    let(:dev_tooling) do
      ["lib/hecks/fuzzing/", "lib/hecks/fuzzing.rb", "lib/hecks/bench/", "lib/hecks/bench.rb",
       "lib/hecks/corpus.rb", "lib/hecks/codemod.rb", "lib/hecks/query_ir.rb",
       "lib/hecks/grammar/evolve.rb", "lib/hecks/doc/"]
    end

    it "ships exe/hecks, executable, as the gem's one command" do
      expect(gemspec.files).to include("exe/hecks")
      expect(gemspec.bindir).to eq("exe")
      expect(gemspec.executables).to eq(["hecks"])
      expect(File.executable?(File.join(root, "exe/hecks"))).to be(true)
    end

    it "leaves every repository-only tool out of the package" do
      missing = dev_tooling.reject { |path| File.exist?(File.join(root, path)) }
      expect(missing).to be_empty, "named here but gone from the repository: #{missing.join(', ')}"

      shipped = gemspec.files.select { |file| dev_tooling.any? { |path| file == path || file.start_with?(path) } }
      expect(shipped).to be_empty, "repository-only tooling in the packaged gem: #{shipped.join(', ')}"
    end

    # Copies exactly the packaged files into a directory of their own and loads
    # them there in a fresh Ruby without Bundler, so a file `require "hecks"` or
    # the command needs that the package leaves out fails as a `LoadError`, and a
    # hecks file found anywhere but the copy is reported.
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
        expect(out).to include("usage: hecks <command>")
      end
    end
  end
end
