# frozen_string_literal: true

require_relative "mcp_selection_checkout"
require "hecks/hecks/adapters/session_line"

# Builds a session's start command for a run held in a checkout, and reads its `--agent`.
module SessionLineWords
  # A credential setting that records the roles it is asked about and scrubs none.
  class Scrubbing
    attr_reader :roles

    def initialize = @roles = []

    def scrub?(role)
      @roles << role
      false
    end
  end

  def scrubbing = (@scrubbing ||= Scrubbing.new)

  def words(**held)
    Hecks::Adapters::SessionLine.new(command: "claude", nice: [], credentials: scrubbing)
                                .arguments({ run: "r1", brief: "b", repo: checkout, **held })
  end

  def role_of(words) = words[words.index("--agent") + 1]
end
