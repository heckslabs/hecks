# frozen_string_literal: true

require_relative "../../cli/console"

module Hecks
  module Adapters
    # The `Terminal` port's adapter: the interactive session an operator types into.
    #
    # The journal records that a session was opened and how it ended, not what was typed in it.
    # IRB is started here and nowhere else; a caller that must not open a real session (a spec)
    # replaces the launcher with `Terminal.launcher=`.
    class Terminal
      class << self
        # @return [#call, nil] starts the interactive session; IRB when nil
        attr_accessor :launcher
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Boots the record's domain and drops into an interactive console; returns when the
      # session ends.
      #
      # @param held [Hash] the `Operation` record: `subject` is the domain directory, or absent
      #   for the bundled pizzas domain
      # @return [Hash{Symbol => Hash}] `output:` a one-line note that the session ended
      def open(**held)
        subject = held[:subject]
        domain  = subject.is_a?(Hash) ? subject[:value] : subject
        launcher = self.class.launcher
        launcher ? CLI::Console.call(domain, launcher: launcher) : CLI::Console.call(domain)

        { output: { value: "console session ended (#{domain || 'pizzas'})" } }
      end
    end
  end
end
