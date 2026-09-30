# frozen_string_literal: true

require "yaml"

module Hecks
  # The table of what each retired `bin/` script became in hecks 3.0.0 (ADR 0080): a command on
  # the Hecks domain, run through `exe/hecks`. `docs/tools.md` is pinned to it.
  module ThreeZero
    # Each retired script's name mapped to the 3.0 form that replaced it.
    FORMS = YAML.safe_load_file(File.join(__dir__, "three_zero/forms.yml")).freeze
  end
end
