# frozen_string_literal: true

require "json"

# Answers git and gh as GitHub would for one draft and one CI run of a pushed ci/<branch>: the run
# is queued for `running` reads, then completed with `jobs`.
class FakeBranchCi
  attr_reader :calls
  attr_accessor :jobs, :running

  def initialize
    @running = 0
    @calls = []
    @jobs = [{ "id" => 1, "name" => "rspec", "conclusion" => "success" }]
  end

  def call(argv, chdir:)
    @calls << argv
    [true, answer(argv.last.to_s)]
  end

  private

  def answer(path)
    return "" unless path.start_with?("repos/")
    return JSON.generate([{ "number" => 7 }]) if path.include?("pulls?")
    return JSON.generate([{ "jobs" => jobs }]) if path.include?("/jobs")

    @running -= 1
    JSON.generate("workflow_runs" => [{ "id" => 99, "name" => "CI", "status" => @running.negative? ? "completed" : "queued" }])
  end
end
