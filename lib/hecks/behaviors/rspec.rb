require_relative "../behaviors"

# Hecks::Behaviors::RSpec.describe_file(path) registers one `it` per test in a `.behaviors` file,
# so a consumer's `bundle exec rspec` runs it. The file is parsed at collection time; each test
# runs lazily inside its own `it`.
#
#   require "hecks/behaviors/rspec"
#
#   Dir.glob("bluebook/**/*.behaviors").each do |path|
#     Hecks::Behaviors::RSpec.describe_file(path)
#   end
module Hecks
  module Behaviors
    # Registers one example per test in a `.behaviors` file so a consumer's suite runs it.
    module RSpec
      module_function

      # Registers an rspec example group for one `.behaviors` file, one `it` per test.
      #
      # A parse error surfaces as a failing "loads without a parse error" example.
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
