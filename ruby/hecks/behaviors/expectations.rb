# Hecks::Behaviors::Expectations
#
# Verdict-producing assertions for the Runner. Each method returns a
# Runner::TestRun struct.
#
# Reserved expect keys (interpreted here; everything else falls through
# to plain field equality against the post-dispatch aggregate state):
#   refused      → assert command was rejected with this given message
#   emits        → assert event bus published this exact ordered list
#   <attr>_size  → assert the named list attribute has this size
#   count        → assert query result count
#   ok           → "true" sentinel: dispatch succeeded, nothing to compare
#
# The runner builds verdicts via Expectations.check_state /
# Expectations.check_query.
#
# Returns Runner::TestRun instances — Runner defines TestRun and is
# loaded by the requiring side; we avoid a require_relative cycle.

module Hecks
  module Behaviors
    module Expectations
      module_function

      def assert_refused(test, expected, _kind, err)
        return nil unless expected
        actual = err.message
        if actual == expected
          Runner::TestRun.new(test.description, :pass, nil)
        else
          Runner::TestRun.new(test.description, :fail,
            "expected refused: #{expected.inspect}, got: #{actual.inspect}")
        end
      end

      def check_state(test, state, rt, pre_event_count)
        test.expect.each do |key, expected|
          k = key.to_s
          next if k == "refused"
          next if k == "ok" && (expected == "true" || expected == "\"true\"")

          if k == "emits"
            verdict = check_emits(test, rt, pre_event_count, expected)
            return verdict if verdict
            next
          end
          if k.end_with?("_size")
            verdict = check_size(test, state, k[0...-5], expected)
            return verdict if verdict
            next
          end

          actual = state.get(k).to_display
          if actual != expected.to_s
            return Runner::TestRun.new(test.description, :fail,
              "expected #{k}: #{expected.inspect}, got #{actual.inspect}")
          end
        end
        Runner::TestRun.new(test.description, :pass, nil)
      end

      def check_query(test, rt)
        result = rt.resolve_query(test.tests_command, test.input)
        expected = test.expect[:count] || test.expect["count"]
        return Runner::TestRun.new(test.description, :pass, nil) unless expected
        actual = case result["state"]
                 when Array then result["state"].size
                 when Hash  then 1
                 else 0
                 end
        if actual != expected.to_i
          return Runner::TestRun.new(test.description, :fail,
            "expected query count == #{expected}, got #{actual}")
        end
        Runner::TestRun.new(test.description, :pass, nil)
      end

      def check_emits(test, rt, pre_event_count, expected)
        actual = rt.event_bus[pre_event_count..].map { |e| e[:name] }
        expected_events = parse_event_list(expected)
        return nil if actual == expected_events
        Runner::TestRun.new(test.description, :fail,
          "expected emits: #{expected_events.inspect}, got #{actual.inspect}")
      end

      def check_size(test, state, field, expected)
        v = state.get(field)
        return nil unless v.list?
        actual = v.list_size
        return nil if actual == expected.to_i
        Runner::TestRun.new(test.description, :fail,
          "expected #{field}.size == #{expected}, got #{actual}")
      end

      # Accept Array (from Ruby DSL) or string source-token form
      # (`"[E1, E2]"` from Rust IR), returning a uniform Array<String>.
      def parse_event_list(raw)
        return raw.map(&:to_s) if raw.is_a?(Array)
        s = raw.to_s.strip.delete_prefix('[').delete_suffix(']')
        return [] if s.strip.empty?
        s.split(',').map { |x| x.strip.delete_prefix('"').delete_suffix('"') }
         .reject(&:empty?)
      end
    end
  end
end
