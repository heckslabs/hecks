# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/shell"
require "hecks/hecks/adapters/claude_transcript"
require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class Metering
      # The outside the meter reads, each as a callable the spec stands in for: the sessions
      # `claude agents --json --all` lists, the `ps` table, the machine's `sysctl` and `vm_stat`,
      # the AgentRun ledger by session id, and each session's transcript time. A read that fails
      # answers empty, so a missing tool meters nothing rather than stopping the beat.
      class LiveReads
        PS = %w[ps -axo pid=,ppid=,rss=,%cpu=,command=].freeze

        # Where Claude files each directory's transcripts, the directory's path with `/` and `.`
        # made `-`.
        PROJECTS = File.join(Dir.home, ".claude", "projects")
        PATH_MARK = %r{[/.]}

        # @param registry [Runtime::Registry, nil] whose AgentRun ledger names each session's run
        # @param shell [Shell] runs the programs
        def initialize(registry, shell: Shell.new)
          @registry = registry
          @shell = shell
          @transcript = ClaudeTranscript.new
        end

        # @return [Array<Hash>] the sessions `claude agents` lists
        def listing
          result = @shell.capture("claude", "agents", "--json", "--all")
          result.ok? ? JSON.parse(result.out) : []
        rescue JSON::ParserError, SystemCallError
          []
        end

        # @return [String] the `ps` table
        def processes
          result = @shell.capture(*PS)
          result.ok? ? result.out : ""
        rescue SystemCallError
          ""
        end

        # @return [Hash] `memsize:`, `perf_cores:`, `loadavg:` and `vm_stat:`
        def machine
          { memsize: sysctl("hw.memsize"), perf_cores: sysctl("hw.perflevel0.physicalcpu"),
            loadavg: sysctl("vm.loadavg"), vm_stat: out("vm_stat") }
        end

        # @return [Hash{String => Hash}] each session id's run: `run:`, `agent:`, `works_as:`, `work:`
        def runs
          aggregate = @registry&.bluebook("Hecks")&.aggregates&.find { |candidate| candidate.hecks_name == "AgentRun" }
          return {} unless aggregate

          @registry.repository("Hecks", aggregate).all.each_with_object({}) do |run, held|
            session = value(run, :session)
            held[session] = ran(run) unless session.empty?
          end
        end

        # @param entry [Hash] a listed session
        # @return [Time, nil] when its transcript last changed: first where its directory files it,
        #   else wherever it is
        def activity(entry)
          filed = File.join(PROJECTS, entry["cwd"].to_s.gsub(PATH_MARK, "-"), "#{entry["sessionId"]}.jsonl")
          File.exist?(filed) ? File.mtime(filed) : @transcript.modified_at(entry["sessionId"].to_s)
        rescue SystemCallError
          nil
        end

        private

        def ran(run)
          { run: value(run, :run), agent: value(run, :agent), works_as: value(run, :works_as), work: value(run, :work) }
        end

        def value(record, name) = StartedWork.value(record, name).to_s

        def sysctl(name) = out("sysctl", "-n", name).strip

        def out(*command)
          result = @shell.capture(*command)
          result.ok? ? result.out : ""
        rescue SystemCallError
          ""
        end
      end
    end
  end
end
