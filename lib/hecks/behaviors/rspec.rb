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
        ::RSpec.describe(File.basename(path), &examples_for(Behaviors.parse(path)))
      end

      # @param parsed [Behaviors::ParseResult] the parsed `.behaviors` file
      # @return [Proc] the body of the example group: one `it` per test and adapter variant, or the
      #   parse failure
      def examples_for(parsed)
        return proc { it("loads without a parse error") { raise parsed.parse_error } } if parsed.parse_error

        cases = Behaviors.variants(parsed.suite).product(parsed.tests)
        proc do
          cases.each do |(label, adapters), test|
            it(RSpec.title(test, label)) { RSpec.pass!(test, parsed.suite, adapters) }
          end
        end
      end

      # Runs one test against one variant's adapters.
      #
      # @raise [RuntimeError] with the test's message when it does not pass
      def pass!(test, suite, adapters)
        run = Expectations.run_one(test, suite, adapters: adapters)
        raise run.message if run.status != :pass
      end

      # @return [String] the test's description, naming the adapters its variant picked
      def title(test, label) = label ? "#{test.description} (with #{label})" : test.description
    end
  end
end
