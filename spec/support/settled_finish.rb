# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/landing/settled_rebase"
require_relative "bluebook_conflict_repo"

# Runs a landing's finish of the branch `adds-c` in a {BluebookConflictRepo}, judged by a stand-in
# gate that is always green, and answers the refusal when it refuses. An includer sets `repo`.
module SettledFinish
  # A stand-in quick gate that passes.
  GREEN = lambda do |_dir|
    Hecks::Adapters::Shell::Result.new('{"status": "completed"}', "", Struct.new(:success?).new(true))
  end

  # @param onto [String] the branch the finish rebases onto
  # @return [void]
  def finish(onto = "trunk")
    Hecks::Adapters::GitLanding::Finisher.new(
      Hecks::Adapters::Git.new, repo.dir, branch: "adds-c", onto: onto, gate: GREEN
    ).prepare
  end

  # @param onto [String] the branch the finish rebases onto
  # @return [String, nil] why the finish refused; nil when it passed
  def refusal(onto = "trunk")
    finish(onto)
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  # @param name [String] the aggregate to add
  # @return [String] the base bluebook with it added
  def adding(name) = BluebookConflictRepo.adding(name)
end
