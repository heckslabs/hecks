# frozen_string_literal: true

require "rspec/core"

module Hecks
  module CLI
    # The command behind `hecks run_spec_example`: runs one spec file filtered to one example
    # through `RSpec::Core::Runner`, so a `hecks quality_control bug.log --demonstration` string
    # needs no `-e` quoting.
    module SpecExample
      USAGE = "usage: hecks run_spec_example <spec_file> <example description substring>"

      module_function

      # Runs the example whose description contains the substring.
      #
      # @param argv [Array<String>] the spec file, then the description substring
      # @return [Integer] RSpec's own exit status: 0 when every example passed
      # @raise [SystemExit] with the usage line unless exactly two arguments are given
      def call(argv)
        abort USAGE if argv.length != 2

        RSpec::Core::Runner.run(["--example", argv[1], argv[0]])
      end
    end
  end
end
