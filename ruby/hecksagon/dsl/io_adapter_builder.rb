module Hecksagon
  module DSL

    # Hecksagon::DSL::IoAdapterBuilder
    #
    # Optional-block builder for an IO adapter. Collects `on :Event`
    # declarations inside the block body so the adapter records which
    # events it reacts to.
    #
    #   adapter :fs, root: "." do
    #     on :Replicated
    #     on :Snapshotted
    #   end
    #
    # The Rust parser's `extract_on_events` reads `on :Name` tokens
    # from the joined adapter body ; this builder is the Ruby-side
    # mirror. Only the `on` method is recognised inside the block —
    # anything else raises NoMethodError so typos surface early rather
    # than becoming silent drift from Rust.
    #
    class IoAdapterBuilder
      attr_reader :on_events

      def initialize
        @on_events = []
      end

      # Declare an event name this adapter reacts to.
      #
      #   on :ReplicatedSnapshot
      #
      def on(event_name)
        @on_events << event_name.to_s
      end
    end
  end
end
