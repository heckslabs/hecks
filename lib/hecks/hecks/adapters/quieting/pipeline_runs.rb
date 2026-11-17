# frozen_string_literal: true

require_relative "../shell"
require_relative "../dispatching/work_items"
require_relative "../claude_executable"
require_relative "../claude_resolving_shell"
require_relative "../claude_session_listing"

module Hecks
  module Adapters
    class Quieting
      # The agent runs that are live, their sessions stopped, and the Work items they held
      # returned to
      # the plan. A session the owner works in has no run, so it is never touched, and it is named
      # so
      # the report can say what was left running.
      class PipelineRuns
        # The reason a held item gives for going back to the plan.
        REASON = "a merge window was opened: the pipeline is held so a train can merge"

        # @param registry [Runtime::Registry, nil] whose runs and Work items are read
        # @param root [String] the checkout whose `exe/hecks` runs the yield and the retire
        # @param doers [Hash] stand-ins: `stop:` stops one session by its id, `yield_back:` returns
        #   one Work item to the plan, `quiet:` says whether a session already stopped, and
        #   `retire:` asks `AgentRun.Retire` to close a run by its key
        def initialize(registry, root: Dir.pwd, **doers)
          @items = Dispatching::WorkItems.new(registry)
          @doers = doers
          @root = root
        end

        # @return [Hash{String => String}] each live run's key with the session it holds
        def live
          @items.runs.select { |_, run| run[:status] == "started" && !run[:session].to_s.empty? }
                .transform_values { |run| run[:session] }
        end

        # Stops the session of every live run that still works and returns the items they held to
        # the plan. A run whose session has stopped is not stopped again: it is asked to retire,
        # which the domain allows only once `claude agents` does not list the session.
        #
        # @return [Hash{Symbol => Array<String>}] `sessions:` the ids stopped, `gone:` the ids
        #   already stopped, and `items:` the keys returned to the plan
        def stop_all
          held = live
          quiet, working = held.partition { |_, session| quieter.call(session) }.map(&:to_h)
          working.each_value { |session| stopper.call(session) }
          quiet.each_key { |key| retirer.call(key) }
          { sessions: working.values, gone: quiet.values, items: return_items(held.keys) }
        end

        private

        def stopper = @doers[:stop] || ->(session) { Shell.new.capture("claude", "stop", session) }

        def yielder = @doers[:yield_back] || ->(key) { yield_argv(@root, key) }

        def quieter = @doers[:quiet] || ->(session) { listing.quiet?(session) }

        def retirer = @doers[:retire] || ->(key) { retire_argv(@root, key) }

        # The one listing a window asks which sessions are already stopped.
        def listing
          @listing ||= ClaudeSessionListing.new(
            ClaudeExecutable::COMMAND,
            shell: ClaudeResolvingShell.new(executable: ClaudeExecutable.new(candidates: ClaudeExecutable::CANDIDATES))
          )
        end

        # The Launcher's retire needs a filling's whole dependencies; a window asks the one command.
        def retire_argv(root, key)
          Shell.new.capture("exe/hecks", "AgentRun.retire!", "to=#{key}", "--wait", chdir: root)
        end

        def return_items(keys)
          started = @items.started.map(&:key)
          keys.select { |key| started.include?(key) }.each { |key| yielder.call(key) }
        end

        def yield_argv(root, key)
          Shell.new.capture("exe/hecks", "tickets", "Work.yield!", "to=#{key}", "reason.value=#{REASON}", "--wait",
                            chdir: root)
        end
      end
    end
  end
end
