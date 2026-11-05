require "spec_helper"
require "open3"
require "rbconfig"

# The grammar table and the verdict file are named by `VerdictCache.language_digest`: the library's
# files without the consumer trees and the applied trees, the domains built in the language. This
# spec keeps that list honest, so an edit to a domain keeps the table and an edit to the language
# never does.
RSpec.describe Hecks::Bluebook::MetaValidator::VerdictCache, ".language_digest" do
  let(:cache) { described_class }
  let(:gem_root) { File.expand_path("..", __dir__) }
  let(:lib) { Dir.mktmpdir("hecks-language-digest") }

  after { FileUtils.rm_rf(lib) }

  def language_digest = cache.digest_of(lib, skip: [cache::CONSUMER_TREES, cache::APPLIED_TREES])

  # The language digest of the scratch tree before and after a rewrite of one file.
  def around_edit(relative)
    file = File.join(lib, "hecks", relative)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "X = 1\n")
    before = language_digest
    File.write(file, "X = 2\n")
    [before, language_digest]
  end

  it "ignores an edit to a bluebook inside an applied tree" do
    expect(around_edit("hecks/deliver/deliver.bluebook")).to all(eq(language_digest))
  end

  it "ignores an edit to an adapter inside an applied tree" do
    expect(around_edit("tickets/adapters/store.rb")).to all(eq(language_digest))
  end

  it "covers the language's own trees", :aggregate_failures do
    %w[bluebook/j.rb language/bluebook/aggregate.bluebook runtime/dispatcher.rb].each do |relative|
      before, after = around_edit(relative)

      expect(after).not_to eq(before), "an edit to #{relative} must change the digest"
    end
  end

  it "leaves the code digest sensitive to an applied tree, for the caches that key on it" do
    before, after = around_edit_code("hecks/deliver.bluebook")

    expect(after).not_to eq(before)
  end

  def around_edit_code(relative)
    file = File.join(lib, "hecks", relative)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "1\n")
    before = cache.digest_of(lib)
    File.write(file, "2\n")
    [before, cache.digest_of(lib)]
  end

  # The child's program: it lists the Ruby it loaded from an applied tree once the grammar table is
  # built, and again once the Hecks domain is described. A declaration (`.bluebook`, `.hecksagon`,
  # `.world`) is data and is keyed by its own IR, so only Ruby counts.
  APPLIED_RUBY_SCRIPT = <<~RUBY.freeze
    require "json"
    $loaded_ruby = []
    Kernel.prepend(Module.new do
      def load(file, *rest)
        $loaded_ruby << File.expand_path(file.to_s) if file.to_s.end_with?(".rb")
        super
      end
    end)
    require "hecks"
    lib = File.expand_path("lib")
    applied = lambda do
      ran = ($LOADED_FEATURES + $loaded_ruby).select { |file| file.start_with?(lib + "/") }
      ran.map { |file| file.delete_prefix(lib) }.uniq.sort
         .select { |rel| rel.match?(Hecks::Bluebook::MetaValidator::VerdictCache::APPLIED_TREES) }
    end
    Hecks::Bluebook::MetaValidator::SyntaxBoot.call
    booted = applied.call
    Hecks.describe(File.expand_path("lib/hecks/hecks")).registry
    puts JSON.generate(booting: booted, describing: applied.call)
  RUBY

  def applied_ruby_loaded
    scratch = Dir.mktmpdir("hecks-language-digest-cache")
    env = { "XDG_CACHE_HOME" => scratch, "HECKS_ENVIRONMENT" => "memory" }
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(gem_root, "lib"), "-e", APPLIED_RUBY_SCRIPT,
                                      chdir: gem_root)
    raise "child failed: #{err}" unless status.success?

    JSON.parse(out.lines.last)
  ensure
    FileUtils.rm_rf(scratch) if scratch
  end

  it "loads no Ruby from an applied tree before the grammar table is built, and only adapters after",
     :aggregate_failures, :process do
    loaded = applied_ruby_loaded

    expect(loaded["booting"]).to eq([])
    expect(loaded["describing"].reject { |file| file.include?("/adapters/") }).to eq([])
  end
end
