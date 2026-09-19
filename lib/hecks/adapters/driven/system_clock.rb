module Hecks
  module Adapters
    # The real `clock` fulfillment — the machine's own time, in seconds.
    #
    # Whole seconds on purpose. The sublanguage does integer arithmetic, a
    # staleness window is measured in minutes, and sub-second precision in a
    # durable ledger is precision nobody reads and every diff has to ignore.
    module SystemClock
      module_function

      # Reads the machine's own current time.
      #
      # @return [Integer] the current time, in Unix epoch seconds
      def now = Time.now.to_i
    end
  end
end
