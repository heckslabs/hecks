# frozen_string_literal: true

require_relative "repository"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # What must hold when a replay ends, read from what the bluebooks recorded and checked
      # against the world.
      #
      # Each check answers nil, or a sentence naming the first run that breaks it. `check` turns
      # those into the divergences the shrinker keys a finding by.
      module Invariants
        # What a check reads: the booted runtime, the replay's world and the runs that began.
        Facts = Struct.new(:runtime, :world, :runs) do
          # @param run [String] a run key
          # @return [Hash, nil] the `Landing` record of the run
          def landing(run) = runtime.query("Delivery::Landing.Outcome", run: { value: run }).first

          # @param run [String] a run key
          # @return [Hash, nil] the `SendTrain` record of the run
          def boarding(run) = runtime.query("Hecks::SendTrain.Outcome", run: { value: run }).first

          # @return [Repository] the replay's repository
          def git = world.repository

          # @return [Array<World::Refusal>] the refusals the world issued
          def refusals = world.refusals

          # @param commit [String, nil] a boarded commit
          # @return [String, nil] the fate of its pull request's CI
          def fate(commit) = world.fate(commit)

          # @param record [Hash, nil] a record
          # @param field [Symbol] one of its attributes
          # @return [Object, nil] the attribute's plain value
          def read(record, field)
            value = record && record[field]
            value.respond_to?(:value) ? value.value : value
          end
        end

        # The checks, in report order.
        NAMES = %i[a_landing_settles a_boarding_settles landed_is_on_main pushed_is_on_remote
                   refusals_are_recorded].freeze

        # The fates of a pull request that leave its boarding queued.
        WAITING = %w[never_starts unmergeable].freeze

        # The states a boarding may rest in once its agent is done.
        RESTING = %w[pushed carried faulted queued red].freeze

        module_function

        # @param facts [Facts] what the replay left
        # @return [Array<Hash>] one `{ field:, detail: }` for each check that does not hold
        def check(facts)
          NAMES.filter_map do |name|
            detail = public_send(name, facts)
            { field: name.to_s, detail: detail } if detail
          end
        end

        # Every landing an agent asked for ended landed or refused.
        def a_landing_settles(facts)
          run = facts.runs.find { |key| !%w[landed refused].include?(facts.read(facts.landing(key), :status)) }
          run && "the landing of #{run} ended #{facts.read(facts.landing(run), :status).inspect}, neither landed nor refused"
        end

        # Every boarding rests in a state the train's answer explains: queued only while its CI
        # has not started or its pull request cannot merge, red only when its CI failed.
        def a_boarding_settles(facts)
          run = facts.runs.find { |key| !rests?(facts, facts.boarding(key)) }
          run && "the boarding of #{run} ended #{facts.read(facts.boarding(run), :status).inspect} " \
                 "with its CI #{facts.fate(facts.read(facts.boarding(run), :boarded)).inspect}"
        end

        def rests?(facts, boarding)
          status = facts.read(boarding, :status)
          fate = facts.fate(facts.read(boarding, :boarded))
          return WAITING.include?(fate) if status == "queued"
          return fate == "red" if status == "red"

          RESTING.include?(status)
        end

        # A commit the `Landing` bluebook recorded as landed is on main.
        def landed_is_on_main(facts)
          facts.runs.each do |run|
            lost = lost_landing(facts, run)
            return lost if lost
          end
          nil
        end

        # A commit the `SendTrain` bluebook recorded as pushed or carried is on the remote.
        def pushed_is_on_remote(facts)
          facts.runs.each do |run|
            lost = lost_push(facts, run)
            return lost if lost
          end
          nil
        end

        def lost_landing(facts, run)
          landing = facts.landing(run)
          landed = facts.read(landing, :landed)
          return unless facts.read(landing, :status) == "landed"
          return if held?(facts, landed, Repository::MAIN)

          "the landing of #{run} is recorded at #{landed}, which main does not hold"
        end

        def lost_push(facts, run)
          boarding = facts.boarding(run)
          status = facts.read(boarding, :status)
          commit = facts.read(boarding, status == "pushed" ? :pushed : :boarded)
          return unless %w[pushed carried].include?(status)
          return if held?(facts, commit, Repository::ORIGIN)

          "the boarding of #{run} is recorded #{status} at #{commit}, which the remote does not hold"
        end

        def held?(facts, commit, ref)
          git = facts.git
          git.known?(commit) && git.ancestor?(commit, git.tip(ref))
        end

        # A refusal the landing or the train port issued is the refusal its record holds.
        def refusals_are_recorded(facts)
          missed = facts.refusals.find { |refusal| !recorded?(facts, refusal) }
          missed && "the #{missed.port} port refused #{missed.run} with #{missed.text.inspect}, and its record does not say so"
        end

        def recorded?(facts, refusal)
          record, status = case refusal.port
                           when "Worktrees" then [facts.landing(refusal.run), "refused"]
                           when "Train"     then [facts.boarding(refusal.run), "faulted"]
                           else return true
                           end
          facts.read(record, :status) == status && facts.read(record, :refusal).to_s.include?(refusal.text)
        end
      end
    end
  end
end
