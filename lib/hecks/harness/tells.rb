# frozen_string_literal: true

module Hecks
  module Harness
    # Each tell the supervisor writes, as the Harness command that records it. The supervisor
    # decides nothing about mail: a `sent` tell becomes a posted Message, and the bluebook's policy
    # delivers it.
    module Tells
      module_function

      # Records one tell in the runtime, as the System role; a tell no command records is skipped.
      #
      # @param runtime [Hecks::Runtime] the booted Harness
      # @param tell [Hash] one tell, as the supervisor wrote it
      # @return [void]
      def record(runtime, tell)
        commands(tell).each do |verb, args|
          Hecks::Runtime::Caller.as(role: "System") { runtime.dispatch_flat("Harness::#{verb}", args) }
        end
      end

      # @param tell [Hash] one tell
      # @return [Array<Array(String, Hash)>] each command and its arguments
      def commands(tell)
        case tell["tell"]
        when "started", "turn_ended", "denied", "stopped" then session_commands(tell)
        when "sent", "delivered", "tick" then mail_commands(tell)
        else []
        end
      end

      def session_commands(tell)
        name = tell["session"]
        case tell["tell"]
        when "started"    then [["Session.RecordStarted", { session: name, claude: plain(tell["claude_session"]) }]]
        when "turn_ended" then [["Session.RecordTurnEnded", turn(tell)]]
        when "denied"     then [["Session.RecordWithheld", { session: name, tool: plain(tell["tool"]) }]]
        else stopped(tell)
        end
      end

      # A sent message is posted, a delivery is timed, and a tick of the supervisor's clock is
      # recorded, so a question left past its window is handed on.
      def mail_commands(tell)
        case tell["tell"]
        when "sent"      then [["Message.Post", post(tell)]]
        when "delivered" then [["Message.RecordDelivered", { message: tell["message"], delivered_at: moment(tell) }]]
        else [["Clock.Tick", { reading: plain("tick-#{tell["at_ms"].to_i}"), now: moment(tell) }]]
        end
      end

      def turn(tell)
        { session: tell["session"], said: plain(tell["text"].to_s),
          outcome: plain(tell["is_error"] ? "error" : "success") }
      end

      def post(tell)
        { key: plain(tell["message"]), sender: plain(tell["session"]), addressee: plain(tell["to"]),
          text: plain(tell["text"]), sent_at: moment(tell), about: tell["about"] && plain(tell["about"]) }
      end

      # The session's exit, then each message it still held, which will not be delivered now.
      def stopped(tell)
        held = Array(tell["undelivered"]).map { |key| ["Message.RecordUndeliverable", { message: key }] }
        [["Session.RecordStopped", { session: tell["session"], code: plain(tell["code"].to_s) }], *held]
      end

      def moment(tell) = plain(tell["at_ms"].to_i)

      def plain(value) = { value: value }
    end
  end
end
