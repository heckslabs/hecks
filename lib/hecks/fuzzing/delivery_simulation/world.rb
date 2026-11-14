# frozen_string_literal: true

require_relative "repository"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # Everything outside the bluebooks that one replay sees: the repository, the pull requests
      # and what their CI does, and the faults a schedule switches on and off.
      #
      # The stand-in adapters answer from it and never decide anything themselves. It also keeps
      # each refusal it issued, so a check can ask whether the bluebooks recorded it.
      class World
        # The refusal a stand-in raises: the port ask records its message as the `refuses` event.
        class Refused < StandardError; end

        # One refusal issued: the port asked, the run it was asked for, and the words.
        Refusal = Struct.new(:port, :run, :text)

        # What a fault step may name, and the setting it changes.
        FAULTS = {
          "red_main"        => [:red, true],
          "green_main"      => [:red, false],
          "hold_store"      => [:held, true],
          "release_store"   => [:held, false],
          "ci_red"          => [:fate, "red"],
          "ci_never_starts" => [:fate, "never_starts"],
          "ci_green"        => [:fate, "green"]
        }.freeze

        # @return [Repository] the repository of this replay
        attr_reader :repository

        # @return [Array<Refusal>] every refusal issued, in order
        attr_reader :refusals

        # @return [String] the lead of this replay's run keys and commit ids
        attr_reader :tag

        # @param tag [String] a name unique to one replay
        # @param pause [#call, nil] what a turn does: the scheduler's yield
        def initialize(tag, pause: nil)
          @tag = tag
          @pause = pause
          @repository = Repository.new(tag)
          @refusals = []
          @pulls = {}
          @settings = { red: false, held: false, fate: "green" }
        end

        # Gives the scheduler the chance to run another agent before the caller touches the world.
        #
        # @return [void]
        def turn
          @pause&.call
          nil
        end

        # Switches a fault on or off. A kind this world does not know changes nothing, so a
        # shrunk step with a simplified kind is still a step.
        #
        # @param kind [String] a key of `FAULTS`
        # @return [void]
        def fault(kind)
          setting, value = FAULTS[kind.to_s]
          @settings[setting] = value if setting
          nil
        end

        # @return [Boolean] whether main is red
        def red? = @settings[:red]

        # @return [Boolean] whether another process holds the store outcomes are recorded in
        def held? = @settings[:held]

        # Records a refusal and raises it.
        #
        # @param port [String] the port asked
        # @param run [String] the run it was asked for
        # @param text [String] the refusal's words
        # @raise [Refused] always
        def refuse(port, run, text)
          @refusals << Refusal.new(port, run, text)
          raise Refused, text
        end

        # Opens the pull request of a boarded commit. Its CI does what the world's CI does now.
        #
        # @param commit [String] the boarded commit
        # @return [String] the fate of its CI: `green`, `red`, `never_starts` or `unmergeable`
        def open_pull(commit)
          @pulls[commit] ||= @settings[:fate]
        end

        # @param commit [String, nil] a boarded commit
        # @return [String, nil] the fate of its pull request's CI, or nil when none was opened
        def fate(commit) = @pulls[commit]

        # Marks a pull request the remote cannot take: its commit is not built on the remote's.
        #
        # @param commit [String] the boarded commit
        # @return [String] the fate it has now, `unmergeable`
        def strand_pull(commit)
          @pulls[commit] = "unmergeable"
        end
      end
    end
  end
end
