require "spec_helper"
require "open3"
require "rbconfig"

# The on-disk chapter-verdict cache lets a boot skip judging chapters an earlier process already
# judged. Every example that touches a file uses its own directory, never the user's cache.
RSpec.describe Hecks::Bluebook::MetaValidator::VerdictCache do
  let(:cache) { described_class }

  let(:scratch) { Dir.mktmpdir("hecks-verdict-cache") }
  let(:gem_root) { File.expand_path("..", __dir__) }

  before do
    cache.reset!
    allow(described_class).to receive(:dir).and_return(File.join(scratch, "verdicts"))
  end

  after do
    cache.reset!
    FileUtils.rm_rf(scratch)
  end

  # The child process's program: it counts the chapters judged for real and digests every IR.
  VERDICT_CACHE_BOOT_SCRIPT = <<~RUBY.freeze
    require "hecks"; require "json"; require "digest"
    Hecks::Bluebook::MetaValidator.singleton_class.prepend(Module.new do
      def hold(bluebook) = ($holds = ($holds || 0) + 1) && super
    end)
    registry = Hecks::Bluebook::MetaValidator.grammar_registry
    irs = registry.bluebooks.sort.map { |name, chapter| [name, JSON.generate(chapter.to_h)] }
    puts JSON.generate(holds: $holds || 0, ir: Digest::SHA256.hexdigest(irs.to_json),
                       verdicts: Hecks::Bluebook::MetaValidator.verdicts.keys.sort)
  RUBY

  # Boots the grammar registry in a fresh Ruby process against `cache_root` and reports how many
  # chapters it judged for real plus a digest of every judged chapter's IR.
  def boot_child(cache_root, env = {})
    child_env = { "XDG_CACHE_HOME" => cache_root, "HECKS_ENVIRONMENT" => "memory" }.merge(env)
    argv = [RbConfig.ruby, "-I", File.join(gem_root, "lib"), "-e", VERDICT_CACHE_BOOT_SCRIPT]
    out, err, status = Open3.capture3(child_env, *argv, chdir: gem_root)
    raise "child failed: #{err}" unless status.success?

    JSON.parse(out.lines.last)
  end

  def cache_files(cache_root) = Dir.glob(File.join(cache_root, "hecks", "hecks_verdict_cache", "verdicts-*.json"))

  def accepted = { refusals: [], declaration: { name: "Probe", aggregates: [{ "a" => :b, 1 => nil }] } }

  def refused = { refusals: ["Probe is not well formed"] }

  # Records a verdict, writes it, and forgets what memory holds, so only the file remains.
  def written_cache
    cache.record("k1", accepted)
    cache.flush
    cache.reset!
  end

  def uncached_boots = Array.new(2) { boot_child(scratch, "HECKS_VERDICT_CACHE" => "off") }

  describe "across processes" do
    it "writes a cache file on a cold boot that judges something", :aggregate_failures do
      cold = boot_child(scratch)

      expect(cache_files(scratch).size).to eq(1)
      expect(cold["holds"]).to be > 0
    end

    it "reads it in a fresh process, judging nothing, to an identical IR", :aggregate_failures do
      cold = boot_child(scratch)
      warm = boot_child(scratch)

      expect(warm["holds"]).to eq(0)
      expect(warm["ir"]).to eq(cold["ir"])
      expect(warm["verdicts"]).to eq(cold["verdicts"])
    end

    it "writes nothing when HECKS_VERDICT_CACHE=off" do
      uncached_boots

      expect(cache_files(scratch)).to be_empty
    end

    it "judges for real when HECKS_VERDICT_CACHE=off", :aggregate_failures do
      first, second = uncached_boots

      expect(second["holds"]).to eq(first["holds"])
      expect(second["holds"]).to be > 0
      expect(second["ir"]).to eq(first["ir"])
    end
  end

  describe "the key" do
    let(:lib) { File.join(scratch, "lib") }

    before do
      FileUtils.mkdir_p(File.join(lib, "hecks"))
      File.write(File.join(lib, "hecks", "a.rb"), "A = 1\n")
      File.write(File.join(lib, "hecks", "b.bluebook"), "grammar\n")
    end

    # The digest of `lib` before and after a rewrite of one file below `lib/hecks`.
    def digests_around_edit(relative)
      file = File.join(lib, "hecks", relative)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "X = 1\n")
      before = cache.digest_of(lib)
      File.write(file, "X = 2\n")
      [before, cache.digest_of(lib)]
    end

    it "is stable for an untouched tree" do
      first = cache.digest_of(lib)

      expect(cache.digest_of(lib)).to eq(first)
    end

    it "changes when any file's bytes change" do
      before = cache.digest_of(lib)
      File.write(File.join(lib, "hecks", "a.rb"), "A = 2\n")

      expect(cache.digest_of(lib)).not_to eq(before)
    end

    it "changes when a file is renamed" do
      before = cache.digest_of(lib)
      File.rename(File.join(lib, "hecks", "a.rb"), File.join(lib, "hecks", "c.rb"))

      expect(cache.digest_of(lib)).not_to eq(before)
    end

    it "changes when a file is added" do
      before = cache.digest_of(lib)
      File.write(File.join(lib, "hecks", "d.rb"), "")

      expect(cache.digest_of(lib)).not_to eq(before)
    end

    it "ignores an edit inside a consumer tree" do
      expect(digests_around_edit("projections/p.rb")).to all(eq(cache.digest_of(lib)))
    end

    it "still covers the judging trees" do
      before, after = digests_around_edit("bluebook/j.rb")

      expect(after).not_to eq(before)
    end

    it "covers the running library, so an edit under lib/ selects another file" do
      expect(cache.code_digest).to eq(cache.digest_of(File.join(gem_root, "lib")))
    end
  end

  describe "the file" do
    it "round-trips a verdict set, including symbols and non-string hash keys" do
      cache.record("k1", accepted)
      cache.record("k2", refused)
      cache.flush
      cache.reset!

      expect(cache.seed).to eq("k1" => accepted, "k2" => refused)
    end

    it "is private to the user" do
      cache.record("k1", accepted)
      cache.flush

      expect(File.stat(cache.path).mode & 0o077).to eq(0)
    end

    it "serves nothing from a corrupt file" do
      FileUtils.mkdir_p(cache.dir)
      File.write(cache.path, "\x00not json{")

      expect(cache.seed).to eq({})
    end

    it "serves nothing from a truncated file" do
      cache.record("k1", accepted)
      cache.flush
      File.truncate(cache.path, File.size(cache.path) / 2)
      cache.reset!

      expect(cache.seed).to eq({})
    end

    it "serves nothing from a file with the wrong shape" do
      FileUtils.mkdir_p(cache.dir)
      File.write(cache.path, JSON.generate("format" => described_class::FORMAT, "entries" => { "$h" => [["k", []]] }))

      expect(cache.seed).to eq({})
    end

    it "refuses a verdict that would read as accepted without a declaration" do
      FileUtils.mkdir_p(cache.dir)
      forged = cache.encode("k" => { refusals: [] })
      File.write(cache.path, JSON.generate("format" => described_class::FORMAT, "entries" => forged))

      expect(cache.seed).to eq({})
    end

    it "serves nothing from a file another user could have written" do
      written_cache
      File.chmod(0o666, cache.path)

      expect(cache.seed).to eq({})
    end

    it "serves nothing from a directory another user could write to" do
      written_cache
      File.chmod(0o777, cache.dir)

      expect(cache.seed).to eq({})
    end

    it "serves nothing when the file belongs to someone else" do
      written_cache
      stranger = instance_double(File::Stat, owned?: false, mode: 0o100600)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(cache.path).and_return(stranger)

      expect(cache.seed).to eq({})
    end

    def stale_and_fresh_files
      FileUtils.mkdir_p(cache.dir)
      old = File.join(cache.dir, "verdicts-old.json")
      fresh = File.join(cache.dir, "verdicts-fresh.json")
      [old, fresh].each { |file| File.write(file, "{}") }
      aged = Time.now - (2 * described_class::STALE_AFTER)
      File.utime(aged, aged, old)
      [old, fresh]
    end

    it "removes only stale files of other code digests when writing" do
      old, fresh = stale_and_fresh_files
      cache.record("k1", accepted)
      cache.flush

      expect([File.exist?(old), File.exist?(fresh), File.exist?(cache.path)]).to eq([false, true, true])
    end
  end

  describe "when it cannot be used" do
    def block_cache_directory
      blocker = File.join(scratch, "blocker")
      File.write(blocker, "a file where a directory is needed")
      allow(described_class).to receive(:dir).and_return(File.join(blocker, "verdicts"))
    end

    it "does not raise or write when the directory is unwritable", :aggregate_failures do
      block_cache_directory
      cache.record("k1", accepted)

      expect { cache.flush }.not_to raise_error
      expect(cache.seed).to eq({})
    end

    # Writes a verdict with the cache switched off, then yields while it is still off.
    def write_while_off
      ENV["HECKS_VERDICT_CACHE"] = "off"
      cache.record("k2", accepted)
      cache.flush
      yield
    ensure
      ENV.delete("HECKS_VERDICT_CACHE")
    end

    it "is off when HECKS_VERDICT_CACHE=off: nothing is read, recorded or written", :aggregate_failures do
      written_cache
      write_while_off do
        expect(cache.seed).to eq({})
        expect(cache.entries).to eq({})
      end
    end

    it "leaves the cache alone when a verdict cannot be encoded", :aggregate_failures do
      cache.record("k1", { refusals: [Object.new] })

      expect { cache.flush }.not_to raise_error
      expect(File.exist?(cache.path)).to be(false)
    end
  end
end
