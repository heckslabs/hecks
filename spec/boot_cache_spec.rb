# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "bootsnap"
require "hecks/boot_cache"

# Each checkout compiles its Ruby into a directory of its own under the hecks cache, claimed with
# the checkout's path, so a removed worktree's entries go with its directory.
RSpec.describe Hecks::BootCache do
  let(:scratch) { File.realpath(Dir.mktmpdir("boot-cache")) }
  let(:root) { File.join(scratch, "checkout").tap { |dir| FileUtils.mkdir_p(dir) } }

  before do
    allow(Hecks::CacheDir).to receive_messages(root: File.join(scratch, "cache", "hecks"), stable?: true)
    allow(Bootsnap).to receive(:setup)
  end

  after { FileUtils.rm_rf(scratch) }

  def own_dir = File.join(scratch, "cache", "hecks", "bootsnap", Hecks::CheckoutSlug.slug(root))

  it "sets Bootsnap up on the checkout's own directory" do
    described_class.setup(root)
    expect(Bootsnap).to have_received(:setup).with(hash_including(cache_dir: own_dir))
  end

  it "records the checkout as the directory's owner" do
    described_class.setup(root)
    expect(Hecks::CheckoutSlug.owner_of(own_dir)).to eq(root)
  end

  it "sets nothing up where the cache does not last between processes" do
    allow(Hecks::CacheDir).to receive(:stable?).and_return(false)
    described_class.setup(root)
    expect(Bootsnap).not_to have_received(:setup)
  end
end
