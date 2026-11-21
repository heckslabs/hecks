require "spec_helper"
require "tmpdir"
require "hecks/tools/comment_style"

# A copy's own settings (`*.local.world`, `*.local.hecksagon`) are never committed, so the comment
# check does not read them as declarations.
RSpec.describe Hecks::Tools::CommentStyle::Run do
  let(:run) { described_class.allocate }

  def found_in(files)
    Dir.mktmpdir do |dir|
      files.each { |name| File.write(File.join(dir, name), "# a\n# b\n# c\n# d\n") }
      run.declaration_files([dir]).map { |path| File.basename(path) }
    end
  end

  it "reads a committed world as a declaration" do
    expect(found_in(%w[shop.world shop.local.world])).to eq(%w[shop.world])
  end

  it "skips a local hecksagon" do
    expect(found_in(%w[shop.hecksagon shop.local.hecksagon])).to eq(%w[shop.hecksagon])
  end

  it "does not take a local world by its name" do
    expect(run.declares?("shop.local.world")).to be(false)
  end
end
