require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/git_train"
require_relative "../../support/revert_landing_repo"

RSpec.describe Hecks::Adapters::GitTrain::Landings do
  include RevertLandingRepo

  before { start_repo }

  after { FileUtils.rm_rf(File.dirname(work)) }

  it "lists each landing with its subject and paths, oldest first" do
    land("one")
    land("two")
    list = described_class.new(Hecks::Adapters::Git.new, work).list(git("rev-parse", "HEAD"), "origin/main")
    expect(list.map { |landing| [landing[:subject], landing[:paths]] })
      .to eq([["land one", ["one.txt"]], ["land two", ["two.txt"]]])
  end
end
