module Hecksagon
  module Structure

    # Hecksagon::Structure::DrivenAdapter
    #
    # Sprint 14 event-subscribed adapter — declared in a
    # `<bluebook>/hecksagons/<service>.hecksagon` file as :
    #
    #   adapter "Name" do
    #     driven on "Context::Aggregate.Event" do |event|
    #       dispatch "Context::Aggregate.Command", attr: "value"
    #     end
    #   end
    #
    # Each handler binds one event → one or more follow-on dispatches.
    # Mirrors rust/src/hecksagon_ir.rs :: DrivenAdapter — same shape, so
    # the canonical-IR parity dump is byte-equal.
    #
    #   adapter = DrivenAdapter.new(name: "ShellAdapter", handlers: [
    #     DrivenHandler.new(event_ref: "Tools::ShellTool.BashRan",
    #                       dispatches: [DrivenDispatch.new(...)])
    #   ])
    #
    class DrivenAdapter
      attr_reader :name, :handlers

      def initialize(name:, handlers: [])
        @name = name.to_s
        @handlers = handlers
      end
    end

    # One `driven on "Event" do |e| ... end` block. Captures the event
    # reference, optional `canned do ... end` defaults, and the list of
    # follow-on dispatches declared inside the body.
    class DrivenHandler
      attr_reader :event_ref, :canned, :dispatches

      def initialize(event_ref:, canned: nil, dispatches: [])
        @event_ref = event_ref.to_s
        @canned = canned
        @dispatches = dispatches
      end
    end

    # One `dispatch "FQN", k: v, k2: v2` line inside a driven/driving
    # handler body. `attrs` is an array of [key_string, value_source_str]
    # pairs matching the Rust IR's tuple list ; values keep their source-
    # token form so the resolver can convert per-attr at fire time.
    class DrivenDispatch
      attr_reader :command, :attrs

      def initialize(command:, attrs: [])
        @command = command.to_s
        @attrs = attrs
      end
    end

    # Sprint 14 memory-canned-defaults — the wrapped-call return declared
    # inline inside a driven handler as :
    #
    #   driven on "X" do |e|
    #     canned do
    #       output "ack"
    #       exit_code 0
    #     end
    #     dispatch "Y", attr: "value"
    #   end
    #
    # Stored as ordered [key, value] pairs (source-token form, mirroring
    # Rust's CannedResponse.values).
    class CannedResponse
      attr_reader :values

      def initialize(values: [])
        @values = values
      end
    end

    # Sprint 14 sibling of DrivenAdapter — externally-triggered adapter
    # declared as :
    #
    #   adapter "Name" do
    #     driving on cron "*/5 * * * *" do |signal|
    #       dispatch "Context::Aggregate.Command", attr: "value"
    #     end
    #   end
    #
    # Mirrors rust/src/hecksagon_ir.rs :: DrivingAdapter.
    class DrivingAdapter
      attr_reader :name, :handlers

      def initialize(name:, handlers: [])
        @name = name.to_s
        @handlers = handlers
      end
    end

    # One `driving on <kind> "<arg>" do |signal| ... end` block. `kind`
    # is the trigger family (`"cron"`, `"http_post"`, `"file_watch"`) ;
    # `arg` is the trigger argument verbatim (cron expression, URL path,
    # filesystem path). `dispatches` reuses DrivenDispatch since the
    # dispatch-line shape is identical.
    class DrivingHandler
      attr_reader :kind, :arg, :dispatches

      def initialize(kind:, arg:, dispatches: [])
        @kind = kind.to_s
        @arg = arg.to_s
        @dispatches = dispatches
      end
    end
  end
end
