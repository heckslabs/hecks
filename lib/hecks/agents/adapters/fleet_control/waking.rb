# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_agents"
require "hecks/hecks/adapters/claude_resumption"
require "hecks/hecks/adapters/listed_status"

module Hecks
  module Adapters
    class FleetControl
      # Finds the listed session that holds a run key and wakes it in place, never as a copy.
      #
      # The holder is the session the AgentRun ledger joins to the key, else the one listed under
      # that name or id. It judges nothing: the Fleet policies refuse a working seat, and this
      # refuses by name only a key no session holds, or a wake that came back as a copy.
      class Waking
        # @param parts [Hash] `listing:`, `ledger:`, `transcripts:` the reads; `shell:` runs claude
        def initialize(**parts)
          @parts = parts
        end

        # @param key [String] the run key, or a session id
        # @return [Hash{Symbol => Object}] `entry:` the holder, `run:` its run key
        # @raise [ConsoleCapture::Failure] when no listed session holds the key
        def holder(key)
          entry = held_by(key) || named(key) || raise(ConsoleCapture::Failure, "no session holds the run key #{key}")
          { entry: entry, run: run_of(entry) }
        end

        # @param key [String] the run key, or a session id
        # @return [String] what was done, in words
        # @raise [ConsoleCapture::Failure] when no session holds the key, `claude` refuses, or the
        #   wake came back under another id
        def wake(key)
          entry = holder(key)[:entry]
          outcome = resumption.call(entry["id"].to_s, entry, prompt(key), env: {}, chdir: directory(entry))
          raise ConsoleCapture::Failure, copied(key, outcome) if outcome[:note]

          "woke session #{entry["id"]} (#{entry["name"]}) in place for #{key}"
        end

        private

        def held_by(key) = entries.select { |entry| run_of(entry) == key }.min_by { |entry| working?(entry) ? 1 : 0 }

        def named(key) = entries.find { |entry| [entry["name"], entry["id"], entry["sessionId"]].include?(key) }

        def entries = @parts[:listing].entries

        def run_of(entry) = @parts[:ledger].run_of(entry["sessionId"].to_s)&.first.to_s

        def working?(entry) = !ListedStatus.idle?(entry) && entry["state"].to_s == "working"

        def directory(entry) = @parts[:transcripts].directory(entry["sessionId"].to_s) || Dir.pwd

        def resumption = ClaudeResumption.new("claude", @parts[:shell])

        def prompt(key) = "You have mail for #{key}: read it with exe/hecks agents Message.inbox recipient.value=#{key}"

        def copied(key, outcome)
          "the wake of #{key} started a copy as #{outcome[:session][:value]}, not the same session: #{outcome[:note][:value]}"
        end
      end
    end
  end
end
