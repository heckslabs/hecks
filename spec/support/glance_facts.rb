# frozen_string_literal: true

require "time"

# The facts a `Glance` spec hands the adapter: sessions, standing episodes, findings and pull
# requests as the readers answer them, and helpers that ask for the kinds and entries built.
module GlanceFacts
  NOW = Time.utc(2026, 11, 20, 12, 0, 0).to_i
  AT = Time.at(NOW).utc

  OWNER_ASK = { id: "s1", run: "r1", status: "blocked", owner: true, detail: "[owner] push main?",
                started: "2026-11-20T09:00:00Z" }.freeze
  BLOCKED = { id: "s2", run: "r2", status: "blocked", owner: false, held: "other repo", detail: "needs an answer" }.freeze
  STALLED = { id: "s3", run: "r3", status: "busy", idle_seconds: 1200 }.freeze
  STOP = { finding: "abcdefghij", stage: "verify", commit: "c", body: "the verify failed" }.freeze

  # @return [Hash] one standing red episode
  def episode(status, began: NOW - 60) = { status: status, began_at: began, culprit: "abc1234567", branch: "b" }

  # @return [Hash] one train pull request as the reader counts it
  def pull(created: Time.at(NOW).utc.iso8601, failed: 0, pending: 0, number: 7)
    { number: number, branch: "train/main-#{number}", created: created, passed: 2, failed: failed, pending: pending }
  end

  # @return [Hash] one epic as the Tickets reader answers it, hand ranked at `ranked` for 14 days
  def epic(ranked:) = { epic: "board-revamp", title: "Board revamp", hand_ranked_at: ranked, hold: 1_209_600 }

  # @return [String] the time `seconds` before now
  def ago(seconds) = Time.at(NOW - seconds).utc.iso8601

  # @return [Hash] a `Glance` row built from the facts
  def glance(data) = described_class.build(data, AT)

  # @return [Array<String>] the kinds of entry the facts make
  def kinds(data) = glance(data)[:entries].map { |item| item[:kind] }

  # @return [Hash] the entry of `kind` the facts make
  def entry(kind:, **data) = glance(data)[:entries].find { |item| item[:kind] == kind }

  # @return [Object] a board answering typed queries from a fixed state, with this registry
  def glance_host(registry)
    Class.new { include Hecks::Adapters::PipelineBoard::TypedAnswers }.new.tap do |host|
      host.instance_variable_set(:@registry, registry)
      host.instance_variable_set(:@now, -> { Time.at(NOW).utc })
      host.define_singleton_method(:state) { { glance: { entries: [], flowing: {} } } }
    end
  end

  # @return [Hash] the `Flow` row the facts make
  def flowing(data) = glance(data)[:flowing]

  # @return [Hash] facts that make an entry of every kind the board lists
  def everything
    { sessions: [OWNER_ASK, BLOCKED, STALLED], approvals: [{ finding: "f1", title: "release v8" }],
      red_episodes: [episode("parked"), episode("requested", began: NOW - 7200)],
      stopped_runs: [STOP], stopped_times: { "abcdefghij" => ago(5 * 3600) },
      train_prs: [pull(created: ago(3 * 3600))],
      epics: [epic(ranked: NOW - (20 * 86_400))], fill: { would_start: [{ slug: "w" }], headroom: 2, age_minutes: 45 } }
  end
end
