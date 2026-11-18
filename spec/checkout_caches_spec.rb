# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/checkout_caches"

# A checkout's Cargo slot and compiled-Ruby cache live outside it, under the hecks cache, and are
# named while it stands so they can be removed once it is gone.
RSpec.describe Hecks::CheckoutCaches do
  let(:scratch) { File.realpath(Dir.mktmpdir("checkout-caches")) }
  let(:tree) { File.join(scratch, "trees", "feature").tap { |dir| FileUtils.mkdir_p(dir) } }

  around do |example|
    saved = ENV.fetch("XDG_CACHE_HOME", nil)
    ENV["XDG_CACHE_HOME"] = File.join(scratch, "cache")
    Hecks::CacheDir.reset!
    example.run
  ensure
    saved ? ENV["XDG_CACHE_HOME"] = saved : ENV.delete("XDG_CACHE_HOME")
    Hecks::CacheDir.reset!
    FileUtils.rm_rf(scratch)
  end

  def slot = File.join(scratch, "cache", "hecks", "cargo-target", Hecks::CheckoutSlug.slug(tree))

  def boot_dir = File.join(scratch, "cache", "hecks", "bootsnap", Hecks::CheckoutSlug.slug(tree))

  def make_both = FileUtils.mkdir_p([slot, boot_dir])

  it "names the checkout's Cargo slot and compiled-Ruby cache" do
    make_both
    expect(described_class.of(tree)).to contain_exactly(slot, boot_dir)
  end

  it "names none of the caches the checkout never made" do
    expect(described_class.of(tree)).to eq([])
  end

  it "removes what it named, though the checkout is gone", :aggregate_failures do
    make_both
    caches = described_class.of(tree)
    FileUtils.rm_rf(tree)
    described_class.remove(caches)
    expect([File.exist?(slot), File.exist?(boot_dir)]).to eq([false, false])
  end
end
