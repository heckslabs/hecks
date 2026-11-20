# frozen_string_literal: true

require "securerandom"

module Hecks
  module Adapters
    class ClaudeCleaning
      # One reap pass decided by Signalbox (ADR 0222, phase 3, reaping), once the Tickets world's
      # `reaping.signalbox` is on. The pass is cleared first: a copy Signalbox does not clear
      # (behind main, lacking the main checkout's local files, or reading a stale view) removes
      # nothing. Then each row of Roundhouse's `Ended` meter is put to `Reaping.Rule`, and only a
      # subject it rules reaped is removed: a session with a plain `claude rm`, a copy with the
      # retire guard `Landing.retire!` uses.
      class SignalboxReap
        # What one pass did.
        #
        # @!attribute [r] removed
        #   @return [Array<String>] the sessions removed
        # @!attribute [r] retired
        #   @return [Array<String>] the copies retired, by branch
        # @!attribute [r] kept
        #   @return [Array<Array(String, String)>] each subject kept, with the given or refusal
        # @!attribute [r] refused
        #   @return [String, nil] why the pass was not cleared, nil when it was
        Result = Struct.new(:removed, :retired, :kept, :refused) do
          # @return [String] the pass on one line, for the reap's report
          def line
            return "signalbox reap refused: #{refused}; nothing removed" if refused

            said = "signalbox reaped #{removed.size} session(s) and #{retired.size} copy(ies); kept #{kept.size}"
            kept.empty? ? said : "#{said}: #{kept.map { |name, why| "#{name} (#{why})" }.join(", ")}"
          end
        end

        # @param door [Dispatching::ReapDoor] Signalbox's clearance and rulings
        # @param meter [#call] answers Roundhouse's `Ended` meter: `sessions:` and `copies:`
        # @param facts [ReapFacts] turns a meter row into the ruling's facts
        # @param remove [#call] takes a session's id, answers nil or why `claude rm` refused
        # @param retire [#call] takes a copy's path, answers nil or why the retirement refused
        def initialize(door:, meter:, facts:, remove:, retire:)
          @door = door
          @meter = meter
          @facts = facts
          @remove = remove
          @retire = retire
        end

        # Removes what Signalbox rules reaped.
        #
        # @return [Result]
        def call = pass(act: true)

        # Removes what Signalbox rules reaped.
        #
        # @return [String] the pass on one line ({Result#line})
        def report = call.line

        # Rules on every subject and removes nothing.
        #
        # @return [Result] what a pass would remove, as `removed` and `retired`
        def verdicts = pass(act: false)

        private

        def pass(act:)
          result = Result.new([], [], [], @door.reap_clearance)
          return result if result.refused

          subjects.each { |facts, handle| judge(facts, handle, result, act) }
          result
        end

        # @return [Array<Array(Hash, String)>] each subject's ruling facts with what removes it
        def subjects
          key = "reap-#{SecureRandom.hex(4)}"
          ended = @meter.call
          Array(ended[:sessions]).map { |row| [@facts.session(row, key), row[:id]] } +
            Array(ended[:copies]).map { |row| [@facts.copy(row, key), row[:path]] }
        end

        def judge(facts, handle, result, act)
          why = @door.reap_refusal(facts) || (act ? act_on(facts, handle) : nil)
          return result.kept << [facts[:subject].to_s, why] if why

          (facts[:kind] == "copy" ? result.retired : result.removed) << facts[:subject].to_s
        end

        def act_on(facts, handle) = facts[:kind] == "copy" ? @retire.call(handle) : @remove.call(handle)
      end
    end
  end
end
