module Hecksagon
  module DSL

    # Hecksagon::DSL::DrivenAdapterBuilder
    #
    # Sprint 14 sibling of IoAdapterBuilder / ShellAdapterBuilder for
    # the quoted-name `adapter "X" do ... end` form :
    #
    #   adapter "ShellAdapter" do
    #     driven on "Tools::ShellTool.BashRan" do |event|
    #       dispatch "Tools::TaskTool.Get",
    #                id: "shell-adapter-smoke"
    #     end
    #
    #     driving on cron "*/5 * * * *" do |signal|
    #       dispatch "Tools::TaskTool.Get",
    #                id: "cron-adapter-smoke"
    #     end
    #   end
    #
    # Captures driven-on handlers (bus events) and driving-on handlers
    # (external triggers — cron, http_post, file_watch) plus the inner
    # dispatch lines, mirroring rust/src/hecksagon_parser.rs
    # `parse_driven_adapter` / `parse_driving_adapter` / `parse_driven_handler`
    # / `parse_driving_handler`. Result feeds Structure::DrivenAdapter and
    # Structure::DrivingAdapter so the canonical IR matches the Rust shape.
    #
    # Ruby block-binding shape: `driven on "X" do |e| ... end` parses as
    # `driven(on("X")) { ... }`. `on` is identity sugar that just returns
    # its argument ; the block lives on `driven` (or `driving`).
    #
    class DrivenAdapterBuilder
      attr_reader :driven_handlers, :driving_handlers

      def initialize
        @driven_handlers = []
        @driving_handlers = []
      end

      # Identity sugar so `driven on "X"` and `driving on cron "*"` read
      # naturally. Returns whatever was handed in — `driven` and `driving`
      # do the real work.
      def on(arg)
        arg
      end

      # External-trigger declaration helpers. Each returns a marker hash
      # `{ kind:, arg: }` that the `driving` keyword consumes to populate
      # the DrivingHandler. Mirrors Rust's parse_driving_handler that
      # captures kind + arg from the source line verbatim.
      def cron(arg)       = { kind: "cron",       arg: arg.to_s }
      def http_post(arg)  = { kind: "http_post",  arg: arg.to_s }
      def file_watch(arg) = { kind: "file_watch", arg: arg.to_s }

      # Declare a driven-on handler. `event_ref` is the FQN of the bus
      # event ("Context::Aggregate.Event"). The block collects inner
      # `dispatch` and `canned` calls via DrivenHandlerBuilder.
      def driven(event_ref, &block)
        handler_builder = DrivenHandlerBuilder.new(event_ref)
        # `instance_exec` (not `instance_eval`) lets us pass an EventProxy
        # as the block parameter — so `|event|` inside the source body
        # binds to a stub that records dotted access (`event.invocation_id`)
        # as a source-token string rather than crashing on the
        # nonexistent method. Mirrors the way Rust's parser captures the
        # whole dispatch line as raw text instead of evaluating it.
        handler_builder.instance_exec(EventProxy.new("event"), &block) if block
        @driven_handlers << handler_builder.build
      end

      # Declare a driving-on handler. `trigger` is the marker hash from
      # `cron(...)` / `http_post(...)` / `file_watch(...)`. The block
      # collects inner `dispatch` calls.
      def driving(trigger, &block)
        kind = trigger[:kind]
        arg  = trigger[:arg]
        handler_builder = DrivingHandlerBuilder.new(kind, arg)
        handler_builder.instance_exec(EventProxy.new("signal"), &block) if block
        @driving_handlers << handler_builder.build
      end
    end

    # Source-token proxy passed in as the block parameter of `driven on
    # ... do |event| ... end` (and the `|signal|` form for `driving on`).
    # The proxy records dotted access into a bareword prefix — so
    # `event.invocation_id` evaluates as a proxy whose `inspect` returns
    # `"event.invocation_id"` (no surrounding quotes), matching the
    # source-token Rust's parser captures from the raw dispatch line.
    # Inherits from BasicObject so `nil?` / `to_s` / `==` don't
    # short-circuit before method_missing fires on chained access.
    class EventProxy < BasicObject
      def initialize(prefix)
        @prefix = prefix.to_s
      end

      def method_missing(name, *_, &_block)
        EventProxy.new("#{@prefix}.#{name}")
      end

      def respond_to_missing?(_, _ = false)
        true
      end

      # The inspect override is the load-bearing piece — DrivenAdapterValueRepr
      # calls value.inspect to get the source-token form, and we want
      # `event.invocation_id` (bare) not `"#<EventProxy …>"`.
      def inspect
        @prefix
      end
    end

    # Inner DSL collector for a `driven on "Event" do ... end` block.
    # Recognises `dispatch "FQN", k: v ...` and `canned do ... end`.
    # Mirrors rust/src/hecksagon_parser.rs :: parse_driven_handler.
    class DrivenHandlerBuilder
      def initialize(event_ref)
        @event_ref = event_ref
        @canned = nil
        @dispatches = []
      end

      # `dispatch "Context::Aggregate.Command", k: v, k2: v2` —
      # captures the FQN + the static attribute pairs. Values are stored
      # as inspect-form strings to match the source-token contract Rust
      # uses (strings keep quotes, ints stay as digit strings).
      def dispatch(command, **attrs)
        attr_pairs = attrs.map { |k, v| [k.to_s, DrivenAdapterValueRepr.repr(v)] }
        @dispatches << Structure::DrivenDispatch.new(command: command, attrs: attr_pairs)
      end

      # `canned do output "ack" ; exit_code 0 end` — captures the canned-
      # response defaults the resolver uses when no .world entry binds
      # this adapter to a real backend.
      def canned(&block)
        canned_builder = CannedResponseBuilder.new
        canned_builder.instance_eval(&block) if block
        @canned = canned_builder.build
      end

      def build
        Structure::DrivenHandler.new(
          event_ref: @event_ref,
          canned: @canned,
          dispatches: @dispatches,
        )
      end

      # Mirror the EventProxy escape hatch one level out. Source bodies
      # like `negative_callback_adapter.hecksagon` make top-level calls
      # such as `rt.find(...)` / `bus.query(...)` inside the handler
      # block ; without method_missing these explode as NoMethodError on
      # the builder. Returning an EventProxy lets local-var assignment
      # (`shell_tool = rt.find(...)`) flow through, and later
      # `shell_tool.stdout` access in `dispatch ... output: shell_tool.stdout`
      # records as a source-token string.
      def method_missing(name, *_args, &_block)
        EventProxy.new(name.to_s)
      end

      def respond_to_missing?(_, _ = false)
        true
      end
    end

    # Inner DSL collector for a `driving on <kind> "<arg>" do ... end`
    # block. Reuses DrivenHandlerBuilder's dispatch logic since the
    # dispatch-line shape is identical between the two grammars.
    class DrivingHandlerBuilder
      def initialize(kind, arg)
        @kind = kind
        @arg = arg
        @dispatches = []
      end

      def dispatch(command, **attrs)
        attr_pairs = attrs.map { |k, v| [k.to_s, DrivenAdapterValueRepr.repr(v)] }
        @dispatches << Structure::DrivenDispatch.new(command: command, attrs: attr_pairs)
      end

      def build
        Structure::DrivingHandler.new(
          kind: @kind,
          arg: @arg,
          dispatches: @dispatches,
        )
      end

      # Same EventProxy escape hatch as DrivenHandlerBuilder — driving
      # handler bodies can legally reference external runtime helpers
      # without crashing the parse.
      def method_missing(name, *_args, &_block)
        EventProxy.new(name.to_s)
      end

      def respond_to_missing?(_, _ = false)
        true
      end
    end

    # Inner DSL collector for the `canned do ... end` block. Any
    # `key value` pair is captured verbatim into CannedResponse.values
    # (source-token form, mirroring Rust's parse_canned_block).
    class CannedResponseBuilder
      def initialize
        @values = []
      end

      def method_missing(name, *args)
        value = args.first
        @values << [name.to_s, DrivenAdapterValueRepr.repr(value)]
      end

      def respond_to_missing?(_, _ = false) = true

      def build
        Structure::CannedResponse.new(values: @values)
      end
    end

    # Helper: render a DSL value back to its source-token form so the
    # Ruby-side IR stores the same string the Rust parser captures from
    # the source text. Strings keep their surrounding quotes (Ruby
    # `inspect` does this), symbols render as `:name`, numbers and
    # booleans render verbatim. Mirrors canonical_ir.rb ::
    # io_option_value_repr.
    module DrivenAdapterValueRepr
      def self.repr(value)
        case value
        when nil then ""
        else value.inspect
        end
      end
    end
  end
end
