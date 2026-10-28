require_relative "composer/plain"
require_relative "composer/workspace"
require_relative "composer/parse"
require_relative "composer/outline"
require_relative "composer/layout"
require_relative "composer/behavior_run"
require_relative "composer/live"
require_relative "composer/toolbox"
require_relative "composer/jobs"
require_relative "composer/check"

module Hecks
  # The Composer's outside, on the hecksagon side: staging a workspace, judging its text and
  # projecting what it declares. The Composer bluebook's bluebook is in `composer/bluebook/`.
  module Composer
  end
end
