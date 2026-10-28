require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/rust_build/project_rust"

# The key a job caches a slice of the generated Rust tree under: a content hash of the generator and
# of the named domains' own sources, so a change to any other domain leaves the cache where it was.
# Every example works in a copy of the checkout, never the checkout itself.
RSpec.describe Hecks::Corpus::GeneratedKey do
  let(:real_root) { Hecks::Corpus::ROOT }
  let(:subset) { %w[lease_clock nested_pieces] }

  # The files a key reads, copied once for the group: the gem's Ruby, the domains the shards read,
  # one more to change, and the generator's own sources.
  before(:all) do
    root = Hecks::Corpus::ROOT
    @root = Dir.mktmpdir("generated-key")
    %w[lib/hecks qa/stress_domains/lease_clock qa/stress_domains/nested_pieces qa/stress_domains/waybill
       rust/codegen/src rust/build/src rust/parser/src rust/src/generated/mod.rs rust/src/generated/pizzas rust/Cargo.toml
       rust-toolchain.toml Gemfile.lock].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      FileUtils.cp_r(File.join(root, path), File.join(@root, path))
    end
  end

  after(:all) { FileUtils.rm_rf(@root) }

  def key(names = subset) = described_class.key(names, root: @root)

  # Appends to a file of the copy while the block runs, then puts it back.
  def with_change(path)
    full = File.join(@root, path)
    original = File.binread(full)
    File.binwrite(full, "#{original}\n# changed\n")
    yield
  ensure
    File.binwrite(full, original)
  end

  # Adds a file to the copy while the block runs, then removes it and the directories it made.
  def with_new_file(path, text = "new\n")
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
    yield
  ensure
    FileUtils.rm_f(full)
    prune_empty(File.dirname(full))
  end

  def prune_empty(dir)
    while dir != @root && Dir.empty?(dir)
      Dir.rmdir(dir)
      dir = File.dirname(dir)
    end
  end

  it "is the same hash for the same files, whatever order the domains are named in", :aggregate_failures do
    first = key
    second = key

    expect(second).to eq(first)
    expect(key(subset.reverse)).to eq(first)
  end

  it "is a sha256 digest" do
    expect(key).to match(/\A\h{64}\z/)
  end

  it "does not move with a file's modification time" do
    path = File.join(@root, "qa/stress_domains/lease_clock/bluebook/lease_clock.bluebook")
    before = key

    FileUtils.touch(path, mtime: Time.now + 3600)

    expect(key).to eq(before)
  end

  it "does not move when an unrelated chapter's bluebook changes" do
    before = key

    with_change("lib/hecks/bulk/bluebook/bulk.bluebook") { expect(key).to eq(before) }
  end

  it "does not move when another domain's file changes" do
    before = key

    with_change("qa/stress_domains/waybill/bluebook/waybill.bluebook") { expect(key).to eq(before) }
  end

  it "does not move for generated output, which a bare checkout does not have", :aggregate_failures do
    before = key

    with_new_file("rust/src/generated/lease_clock/ir.json") { expect(key).to eq(before) }
    with_new_file("rust/codegen/target/debug/hecks-codegen") { expect(key).to eq(before) }
  end

  it "moves when a named domain's own file changes", :aggregate_failures do
    before = key

    with_change("qa/stress_domains/lease_clock/bluebook/lease_clock.bluebook") { expect(key).not_to eq(before) }
    with_new_file("qa/stress_domains/lease_clock/NEW.md") { expect(key).not_to eq(before) }
  end

  it "moves when a chapter a named domain attaches changes" do
    before = key

    with_change("lib/hecks/framework/bluebook/governance.bluebook") { expect(key).not_to eq(before) }
  end

  it "does not move a domain's key for a chapter only another named domain attaches" do
    only_lease_clock = key(%w[lease_clock])

    with_change("lib/hecks/framework/bluebook/governance.bluebook") { expect(key(%w[lease_clock])).to eq(only_lease_clock) }
  end

  it "moves when a generator input changes", :aggregate_failures do
    before = key

    with_change("lib/hecks/rust_build/project_rust.rb") { expect(key).not_to eq(before) }
    with_change("rust/codegen/src/main.rs") { expect(key).not_to eq(before) }
    with_change("lib/hecks/tools/regeneration_run.rb") { expect(key).not_to eq(before) }
    with_change("rust/src/generated/mod.rs") { expect(key).not_to eq(before) }
  end

  it "differs between every domain and a subset" do
    expect(key(nil)).not_to eq(key)
  end

  it "takes no list of domains as every domain" do
    expect(key(nil)).to eq(key(Hecks::Corpus.rust_regen_order(root: @root).map(&:feature)))
  end

  it "hashes no file of an unrelated domain or chapter", :aggregate_failures do
    files = described_class.files(subset, root: @root)

    expect(files.grep(%r{\Aqa/stress_domains/(?!lease_clock|nested_pieces)})).to be_empty
    expect(files.grep(%r{\Alib/hecks/(bulk|deploy|site|tickets|composer)/})).to be_empty
    expect(files).to include("qa/stress_domains/lease_clock/bluebook/lease_clock.bluebook",
                             "lib/hecks/framework/bluebook/governance.bluebook")
  end

  # A hecksagon added to lease_clock's copy while the example runs.
  def with_hecksagon(body, &)
    text = "Hecks.hecksagon \"LeaseClock\" do\n#{body}\nend\n"
    with_new_file("qa/stress_domains/lease_clock/bluebook/odd.hecksagon", text, &)
  end

  def lease_clock_files = described_class.files(%w[lease_clock], root: @root)

  it "hashes every gem chapter file for a domain that attaches one it cannot follow" do
    with_hecksagon("  attaches(\"Gov\" + \"ernance\")") do
      expect(lease_clock_files).to include("lib/hecks/bulk/bluebook/bulk.bluebook")
    end
  end

  it "moves with any chapter for a domain that attaches one it cannot follow" do
    with_hecksagon("  attaches(\"Gov\" + \"ernance\")") do
      wide = key(%w[lease_clock])
      with_change("lib/hecks/bulk/bluebook/bulk.bluebook") { expect(key(%w[lease_clock])).not_to eq(wide) }
    end
  end

  it "follows a chapter's name to the files attaching it reads, its ports file included", :aggregate_failures do
    with_hecksagon("  attaches \"Bulk\"") do
      bulk = "lib/hecks/bulk/bluebook"

      expect(lease_clock_files).to include("#{bulk}/bulk.bluebook", "#{bulk}/bulk.ports.hecksagon")
      expect(lease_clock_files).not_to include("#{bulk}/bulk.hecksagon", "lib/hecks/deploy/bluebook/deploy.bluebook")
    end
  end

  it "lists each file it hashes with its own digest, sorted by path", :aggregate_failures do
    rows = described_class.listing(subset, root: @root)
    paths = rows.map { |row| row.split("  ", 2).last }

    expect(paths).to eq(paths.sort)
    expect(rows).to all(match(/\A\h{64}  \S+\z/))
    expect(described_class.digest(rows)).to eq(key)
  end

  it "refuses a domain that is not one, listing the valid ones", :aggregate_failures do
    expect { key(%w[lease_clock no_such_domain]) }
      .to raise_error(Hecks::Corpus::UnknownDomain, /no_such_domain; valid: .*\blease_clock\b.*\bnested_pieces\b/)
    expect { described_class.files(%w[nope], root: @root) }.to raise_error(Hecks::Corpus::UnknownDomain)
  end

  it "names the committed generated modules the way rust/.gitignore does" do
    ignore = File.read(File.join(real_root, "rust/.gitignore"))

    expect(described_class::COMMITTED_OUTPUT).to eq(ignore.scan(%r{^!/src/generated/(\w+)/$}).flatten)
  end

  it "hashes the committed generated output into every key, and no generated output that is not committed",
     :aggregate_failures do
    expect(described_class.files(subset, root: real_root)).to include("rust/src/generated/pizzas/ir.json")
    expect(described_class.files(subset, root: real_root).grep(%r{\Arust/src/generated/(?!mod\.rs|pizzas/)})).to be_empty
  end

  it "moves when the committed generated output changes, whichever domains are named" do
    before = key

    with_change("rust/src/generated/pizzas/registry.rs") { expect(key).not_to eq(before) }
  end

  it "names the files a domain load reads that DomainLoader lists", :aggregate_failures do
    files = described_class.files(subset, root: real_root)

    Hecks::RustBuild::ProjectRust::DomainLoader::FRAMEWORK_FILES.each do |file|
      expect(files).to include("lib/hecks/#{file}"), file
    end
  end
end
