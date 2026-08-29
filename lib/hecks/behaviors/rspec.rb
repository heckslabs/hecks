require_relative "../behaviors"

# Hecks::Behaviors::RSpec.describe_file(path) — the shim a consumer's
# `bundle exec rspec` uses to run `.behaviors` files as ordinary examples,
# one `it` per test, named by the test's own description string. Same
# shape `spec/guides_spec.rb` uses for doctested guides: the file is
# PARSED at collection time (cheap — `Behaviors.parse`, no test actually
# run yet, just enough to know the `it` names), and each test's own
# `Expectations.run_one` runs lazily inside its own `it`, exactly when
# rspec actually executes it.
#
#   require "hecks/behaviors/rspec"
#
#   Dir.glob("bluebook/**/*.behaviors").each do |path|
#     Hecks::Behaviors::RSpec.describe_file(path)
#   end
module Hecks
  module Behaviors
    # See this file's own header above for what `describe_file` does and
    # how a consumer wires it into their own `bundle exec rspec` run.
    module RSpec
      module_function

      def describe_file(path)
        parsed = Behaviors.parse(path)

        ::RSpec.describe(File.basename(path)) do
          if parsed.parse_error
            it "loads without a parse error" do
              raise parsed.parse_error
            end
          else
            parsed.suite.tests.each do |test|
              it(test.description) do
                run = Expectations.run_one(test, parsed.suite)
                raise run.message if run.status != :pass
              end
            end
          end
        end
      end
    end
  end
end
