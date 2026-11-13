require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools/comment_style"

# The comment check over a directory that holds declaration files beside Ruby ones.
RSpec.describe Hecks::Tools::CommentStyle::Run do
  # A directory holding a bluebook with a long comment block, a Ruby file and a vendored bluebook.
  def tree
    Dir.mktmpdir("hecks-comment-declarations") do |dir|
      long = "#{Array.new(6) { |index| "# line #{index + 1}\n" }.join}Hecks.bluebook \"Shop\" do\nend\n"
      { "shop.bluebook" => long, "vendor/embryonaut_bluebooks/x/bluebook/x.bluebook" => long,
        "plain.rb" => "# frozen_string_literal: true\n" }.each do |name, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), text)
      end
      yield dir
    end
  end

  def long_blocks_in(dir) = described_class.new([dir], only: ["long_block"], baseline: {}).violations

  it "finds a declaration file's long block among a directory's violations" do
    tree { |dir| expect(long_blocks_in(dir).map { |found| File.basename(found.path) }).to eq(["shop.bluebook"]) }
  end

  it "leaves a vendored package's files to the project they come from" do
    tree { |dir| expect(long_blocks_in(dir).map(&:path).grep(/vendor/)).to be_empty }
  end

  it "records a declaration file's long block in the baseline it writes" do
    tree do |dir|
      held = described_class.new([dir], baseline: {}).long_block_baseline
      expect(held[File.join(dir, "shop.bluebook")]).to eq("line 1" => 6)
    end
  end
end
