require "spec_helper"
require "open3"
require "rbconfig"

# **The runtime's scratch files stay out of the gem.** The syntax-boot cache
# and the Storehouse audit log are written on a normal run, so their home
# cannot be `<gem root>/tmp`: an installed gem's directory is read-only.
# `Hecks::CacheDir` picks the XDG cache directory, `~/.cache`, or a private
# directory under the system temp directory, and these examples pin the order,
# the privacy check, and that a real process writes nothing under the gem.
RSpec.describe Hecks::CacheDir do
  let(:scratch) { Dir.mktmpdir("hecks-cache-dir-spec") }
  let(:gem_root) { File.expand_path("..", __dir__) }

  after { FileUtils.rm_rf(scratch) }

  describe ".resolve" do
    it "prefers $XDG_CACHE_HOME/hecks" do
      xdg = File.join(scratch, "xdg")

      root = described_class.resolve(env: { "XDG_CACHE_HOME" => xdg, "HOME" => scratch }, tmpdir: scratch)

      expect(root).to eq(File.join(xdg, "hecks"))
      expect(File.stat(root).mode & 0o077).to eq(0)
    end

    it "uses ~/.cache/hecks when XDG_CACHE_HOME is unset" do
      root = described_class.resolve(env: { "HOME" => scratch }, tmpdir: scratch)

      expect(root).to eq(File.join(scratch, ".cache", "hecks"))
    end

    it "ignores a relative XDG_CACHE_HOME, as the XDG specification says to" do
      root = described_class.resolve(env: { "XDG_CACHE_HOME" => "relative", "HOME" => scratch }, tmpdir: scratch)

      expect(root).to eq(File.join(scratch, ".cache", "hecks"))
    end

    it "falls through to the next candidate when one cannot be created" do
      blocked = File.join(scratch, "blocked")
      File.write(blocked, "a file where a directory is needed")

      root = described_class.resolve(env: { "XDG_CACHE_HOME" => blocked, "HOME" => scratch }, tmpdir: scratch)

      expect(root).to eq(File.join(scratch, ".cache", "hecks"))
    end

    it "uses <tmpdir>/hecks-<uid> when neither is available" do
      root = described_class.resolve(env: {}, tmpdir: scratch, uid: 4242)

      expect(root).to eq(File.join(scratch, "hecks-4242"))
    end

    it "refuses a directory other users can write to and uses a private per-process one instead" do
      shared = File.join(scratch, "hecks-4242")
      Dir.mkdir(shared)
      File.chmod(0o777, shared)

      root = described_class.resolve(env: {}, tmpdir: scratch, uid: 4242)

      expect(root).not_to eq(shared)
      expect(root).to start_with(File.join(scratch, "hecks-"))
      expect(File.stat(root).mode & 0o022).to eq(0)
    end
  end

  describe ".path" do
    it "joins a subdirectory name onto the resolved root" do
      allow(described_class).to receive(:root).and_return(scratch)

      expect(described_class.path("storehouse")).to eq(File.join(scratch, "storehouse"))
    end
  end

  # One real process, so the constants-at-load-time and the gem-relative
  # `__dir__` paths that used to decide this are exercised for real.
  describe "a real process" do
    let(:script) do
      <<~RUBY
        require "hecks"
        Hecks::Storehouse.record!("Pizzas", tool: "state", summary: "spec", source: nil, outcome: { ok: true })
        Hecks::Bluebook::MetaValidator::SyntaxBoot.call
      RUBY
    end

    def run_process(env)
      _out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(gem_root, "lib"), "-e", script)
      raise "subprocess failed: #{err}" unless status.success?
    end

    def gem_tmp_entries
      Dir.glob(File.join(gem_root, "tmp", "{storehouse,hecks_syntax_boot_cache}", "**", "*"))
    end

    it "writes the audit log and the syntax-boot cache under the cache root, not under <gem root>/tmp" do
      before = gem_tmp_entries

      run_process("XDG_CACHE_HOME" => scratch, "HECKS_SYNTAX_BOOT_CACHE" => nil)

      log = File.join(scratch, "hecks", "storehouse", "Pizzas.jsonl")
      expect(JSON.parse(File.read(log))).to include("tool" => "state", "ok" => true)
      expect(Dir.glob(File.join(scratch, "hecks", "hecks_syntax_boot_cache", "*.marshal"))).not_to be_empty
      expect(gem_tmp_entries).to eq(before)
    end

    it "still writes no syntax-boot cache under HECKS_SYNTAX_BOOT_CACHE=off" do
      run_process("XDG_CACHE_HOME" => scratch, "HECKS_SYNTAX_BOOT_CACHE" => "off")

      expect(Dir.glob(File.join(scratch, "hecks", "hecks_syntax_boot_cache", "*"))).to be_empty
    end
  end
end
