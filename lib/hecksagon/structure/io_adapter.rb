module Hecksagon
  module Structure

    # Hecksagon::Structure::IoAdapter
    #
    # One declared IO port — anything that isn't persistence (:memory,
    # :heki) and isn't a shell adapter (:shell). The runtime interprets
    # kind + options to wire the port concretely.
    #
    # Canonical kinds : :fs, :stdout, :stderr, :stdin, :env, :sqlite,
    # :postgres, :information, :runtime_dispatch, and friends. Options
    # are the raw key → value pairs from the DSL call (the runtime
    # decides their meaning). `on_events` lists event names the adapter
    # reacts to, declared via `on :EventName` inside an optional block.
    #
    # Mirrors hecks_life/src/hecksagon_ir.rs :: IoAdapter. The parity
    # suite's canonical dump emits options as `[[key, value_source], …]`
    # where value_source is the Ruby-source repr of the value (what
    # Object#inspect produces for strings, arrays, symbols) — matching
    # the raw-text slice the Rust parser captures.
    #
    #   io = IoAdapter.new(kind: :fs, options: { root: "." }, on_events: [])
    #   io.kind      # => :fs
    #   io.options   # => { root: "." }
    #   io.on_events # => []
    #
    class IoAdapter
      attr_reader :kind, :options, :on_events

      def initialize(kind:, options: {}, on_events: [])
        @kind = kind.to_sym
        @options = options
        @on_events = on_events.map(&:to_s)
      end
    end
  end
end
