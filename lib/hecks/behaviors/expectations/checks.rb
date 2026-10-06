module Hecks
  module Behaviors
    module Expectations
      # The checks of a test's `expect` against what a dispatch or query settled on, and the
      # results they build. Extended onto `Expectations`.
      module Checks
        # Whether `test.expect` names a field, not just one of the special keys.
        #
        # @param test [Behaviors::TestCase] the test case to check
        # @return [Boolean] true if `test.expect` has any key besides `ok`, `refused`,
        #   `emits` or `count`
        def field_expectations?(test)
          test.expect.keys.any? { |key| !SPECIAL_KEYS.include?(key) }
        end

        # A field expectation on a query only makes sense once it has settled on
        # exactly one row; this picks that row (or fails naming the row count).
        #
        # @param test [Behaviors::TestCase] the test case, for the fail message
        # @param rows [Array<Hash>, Hash] the query's own result
        # @return [Hash, Result] `rows` itself when it isn't an Array; its one row when
        #   it holds exactly one; otherwise a `fail_result` naming the row count
        def query_row(test, rows)
          return rows unless rows.is_a?(Array)

          case rows.size
          when 1 then rows.first
          when 0 then fail_result(test, "expect names a field, but the query returned no rows")
          else fail_result(test, "expect names a field, but the query returned #{rows.size} rows — " \
                                 "narrow it with `input`/`expect count: 1` first")
          end
        end

        # Fails a test that expected a refusal but whose dispatch or query went through.
        #
        # @param test [Behaviors::TestCase] the test case to check
        # @param what [String] what succeeded, for the message
        # @return [Result, nil] a `fail_result` when `test.expect` names a refusal; nil otherwise
        def refused_but_succeeded(test, what)
          return unless test.expect.key?(:refused)

          fail_result(test, "expected refused: #{test.expect[:refused].inspect} but #{what} succeeded")
        end

        # Checks `expect emits:` against the events a dispatch appended to the log.
        #
        # @param before [Integer] the event log's length before the dispatch
        # @return [Result, nil] a `fail_result` when the emitted names differ; nil otherwise
        def unexpected_emits(test, runtime, before)
          expected = test.expect[:emits]
          return unless expected

          actual = runtime.registry.event_log[before..].map(&:name)
          return if actual == expected

          fail_result(test, "expected emits: #{expected.inspect}, got #{actual.inspect}")
        end

        # Checks `expect count:` against what a query returned.
        #
        # @return [Result, nil] a `fail_result` when the row count differs; nil otherwise
        def unexpected_count(test, rows)
          expected = test.expect[:count]
          return unless expected

          count = row_count(rows)
          fail_result(test, "expected count: #{expected}, got #{count}") if count != expected
        end

        # @return [Integer] how many rows a query answered: its size, or one for a single row, or
        #   none for nil
        def row_count(rows)
          return rows.size if rows.is_a?(Array)

          rows.nil? ? 0 : 1
        end

        # Checks an `expect ok: true` expectation.
        #
        # @param test [Behaviors::TestCase] the test case to check
        # @return [Result, nil] nil if `test.expect` has no `ok` key or expects `true`;
        #   a `fail_result` if it names anything else
        def check_ok(test)
          return unless test.expect.key?(:ok)

          expected = test.expect[:ok]
          return if expected == true || expected.nil?

          fail_result(test, "expect ok: only accepts true — got #{expected.inspect}")
        end

        # Checks every field-name expectation in `test.expect` against `state`.
        #
        # @param test [Behaviors::TestCase] the test case to check
        # @param state [Hash{Symbol, String => Object}] the settled record's (or query
        #   row's) fields
        # @return [Result, nil] nil if every expected field matches; a `fail_result` for
        #   the first field that names none of `state`'s keys or doesn't match
        def check_fields(test, state)
          test.expect.each do |key, expected|
            next if SPECIAL_KEYS.include?(key)

            failure = field_failure(test, state, key, expected)
            return failure if failure
          end
          nil
        end

        # @return [Result, nil] a `fail_result` when `state` lacks the field or holds another value
        def field_failure(test, state, key, expected)
          unless state.key?(key) || state.key?(key.to_s)
            return fail_result(test, "expect #{key}: names no field on the tested aggregate — " \
                                     "valid expect keys are ok:, refused:, emits:, count: (queries only), " \
                                     "or a real field name")
          end

          actual = normalize(state.key?(key) ? state[key] : state[key.to_s])
          return if actual == normalize(expected)

          fail_result(test, "expected #{key}: #{expected.inspect}, got #{actual.inspect}")
        end

        # Checks a caught domain refusal against `test.expect[:refused]`.
        #
        # @param test [Behaviors::TestCase] the test case to check
        # @param error [StandardError] the caught refusal, a member of `REFUSAL_CLASSES`
        # @return [Result] a `pass_result` if `test` expected this refusal's message, an
        #   `error_result` if it expected none, or a `fail_result` if the message doesn't match
        def check_refusal(test, error)
          expected = test.expect[:refused]
          return error_result(test, "unexpected refusal (#{error.class}): #{error.message}") unless expected

          msg = error.message.to_s
          # hecks's given/ensures refusals render "Command refused —
          # <description>" (RefusalWording) ; a behaviors file names just
          # the description — end_with?/include? bridges the prefix.
          return pass_result(test) if msg == expected || msg.end_with?(expected) || msg.include?(expected)

          fail_result(test, "expected refused: #{expected.inspect}, got #{msg.inspect}")
        end

        # Normalizes both `expect` spellings (bare or `{value: ...}`) and a live
        # `Hecks::Runtime::Value` field to the same bare-scalar-or-plain-hash shape.
        #
        # @param value [Object] a stored field's value, or an `expect` value to compare
        #   it against
        # @return [Object] the bare underlying value: unwrapped from a `Runtime::Value`,
        #   or from a `{value: ...}` Hash; unchanged otherwise
        def normalize(value)
          return Hecks::Runtime::Value.materialize_unwrapped(value) if value.is_a?(Hecks::Runtime::Value)
          return normalize(value[:value]) if value.is_a?(Hash) && value.keys == [:value]

          value
        end

        # Builds a passing result.
        #
        # @param test [Behaviors::TestCase] the test that passed
        # @return [Result] a `:pass` result
        def pass_result(test) = Result.new(description: test.description, status: :pass, message: nil)

        # Builds a failing result.
        #
        # @param test [Behaviors::TestCase] the test whose expectation was not met
        # @param message [String] what was expected versus what happened
        # @return [Result] a `:fail` result
        def fail_result(test, message)  = Result.new(description: test.description, status: :fail, message: message)

        # Builds an errored result.
        #
        # @param test [Behaviors::TestCase] the test that could not run to a conclusion
        # @param message [String] what went wrong
        # @return [Result] an `:error` result
        def error_result(test, message) = Result.new(description: test.description, status: :error, message: message)
      end
    end
  end
end
