# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class BoxState
      # Raised when the box cannot be read: no `deploy-box.sh`, no instance, or an `aws` read that
      # failed. It is a tool's refusal, so the launcher answers the query with the reason and exit
      # 1, and a caller never takes silence for a box that is ready.
      class Unreadable < ConsoleCapture::Failure; end
    end
  end
end
