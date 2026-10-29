# frozen_string_literal: true

module Hecks
  module Adapters
    class LocalRunner
      # Why an experiment could not be run. The runtime records the message as the experiment's
      # refusal, so it names what was wrong and what would have been right.
      class Refused < StandardError; end
    end
  end
end
