# frozen_string_literal: true

require "json"

# A scripted GitHub for the train branch prune: the origin train branches, the closed and open pull
# requests, and the deletes it refuses. It answers `gh` as `TrainSweep` calls it and records
# each call.
class TrainBranchGithub
  OLD   = "2026-11-20T00:00:00Z"
  FRESH = "2026-11-22T11:50:00Z"
  NOW   = Time.utc(2026, 11, 22, 12)

  attr_reader :calls
  attr_accessor :refs, :closed, :open, :refusing

  def initialize
    @calls = []
    @refs = []
    @closed = []
    @open = []
    @refusing = []
  end

  # A pull request as GitHub's REST lists it.
  def self.pull(number, branch, merged: nil, closed: merged, state: "closed")
    { "number" => number, "state" => state, "head" => { "ref" => branch, "sha" => "s#{number}" },
      "created_at" => OLD, "merged_at" => merged, "closed_at" => closed }
  end

  # @return [String] the JSON `gh` prints, or an empty string for a delete
  def call(*args)
    @calls << args
    return delete(args) if args.include?("DELETE")

    body = answer(args.last.to_s)
    JSON.generate(args.include?("--paginate") ? [body] : body)
  end

  # @return [Array<String>] the branches a delete was asked of
  def deleted = @calls.select { |call| call.include?("DELETE") }.map { |call| call.last.split("heads/").last }

  # @return [Array<String>] the REST paths read
  def paths = @calls.map { |call| call.last.to_s }

  private

  def delete(args)
    raise Hecks::Adapters::ConsoleCapture::Failure, "gh api failed: 422" if @refusing.include?(args.last.split("heads/").last)

    ""
  end

  def answer(path)
    return @refs.map { |ref| { "ref" => "refs/heads/#{ref}" } } if path.include?("matching-refs")
    return @closed if path.include?("state=closed")
    return @open if path.include?("state=open")

    { "check_runs" => [], "statuses" => [] }
  end
end
