# frozen_string_literal: true

require "spec_helper"
require_relative "support/standing_world"

# Where each worktree's change stands: in a worktree, on local main only, or on origin/main.
# A change counts as landed by its content, so a rebased or cherry-picked landing is landed.
RSpec.describe "PipelineBoard Standing" do
  let(:base) { Dir.mktmpdir("standing") }
  let(:world) { StandingWorld.new(base) }

  after { FileUtils.rm_rf(base) }

  it "says a change main lacks is in a worktree" do
    world.commit(world.worktree("alpha"), "a.txt", "a")
    expect(world.standing_of("alpha")).to include(standing: "worktree", say: "in a worktree, not landed")
  end

  it "says a change on local main only is on local main, not yet on origin" do
    world.commit(world.worktree("beta"), "b.txt", "b")
    world.pick("beta")
    expect(world.standing_of("beta")).to include(standing: "local_main", say: "on local main, not yet on origin")
  end

  it "says a change on origin/main is on origin/main" do
    world.commit(world.worktree("gamma"), "g.txt", "g")
    world.pick("gamma")
    world.push
    expect(world.standing_of("gamma")).to include(standing: "origin_main", say: "on origin/main")
  end

  it "reads a rebased landing under another sha as landed" do
    path = world.worktree("delta")
    world.commit(world.root, "m.txt", "m")
    world.commit(path, "d.txt", "d")
    world.pick("delta")
    world.push
    expect(world.standing_of("delta")[:standing]).to eq("origin_main")
  end

  it "names a worktree dirty when it has uncommitted files" do
    File.write(File.join(world.worktree("eps"), "loose.txt"), "x")
    expect(world.standing_of("eps")).to include(dirty: 1)
  end
end
