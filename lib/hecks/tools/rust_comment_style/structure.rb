# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # Tracks whether the line just observed sits inside a `#[cfg(test)]`
      # module, by brace depth.
      class TestCfgTracker
        TEST_CFG = /\A\s*#\[cfg\(test\)\]/

        # Starts outside every module, at brace depth zero.
        def initialize
          @depth = 0
          @test_depth = nil
        end

        # Updates the tracked brace depth with one more source line.
        def observe(line)
          @depth += line.count("{") - line.count("}")
          @test_depth = @depth if line.match?(TEST_CFG)
          @test_depth = nil if @test_depth && @depth < @test_depth
        end

        # Answers whether the line just observed sits inside a test module.
        def inside?
          !@test_depth.nil?
        end
      end

      # The structural categories: `pub` items with no `///` doc above, and files with no `//!`
      # module doc at the top.
      module Structure
        private

        # Attribute lines between the doc and item are skipped.
        def structure_violations
          (test_tree? ? [] : missing_doc_violations) + missing_module_doc_violation
        end

        def test_tree?
          path.split("/").include?("tests")
        end

        def missing_doc_violations
          tracker = TestCfgTracker.new
          @lines.each_with_index.filter_map do |line, index|
            tracker.observe(line)
            missing_doc_violation(line, index + 1) unless tracker.inside?
          end
        end

        def missing_doc_violation(line, line_number)
          match = PUB_ITEM.match(line)
          return unless match
          return if match[1] == "fn" && SELF_EVIDENT_FNS.include?(match[2])
          return if doc_above?(line_number)

          Violation.new(path, line_number, "missing_doc", "#{match[1]} #{match[2]}")
        end

        def doc_above?(line_number)
          cursor = line_number - 1
          cursor -= 1 while cursor.positive? && @lines[cursor - 1].to_s.match?(ATTR_LINE)
          @lines[cursor - 1].to_s.match?(DOC_LINE)
        end

        def missing_module_doc_violation
          return [] if test_tree?
          return [] unless ["mod.rs", "lib.rs", "main.rs"].include?(File.basename(path))
          return [] if @lines.first(3).any? { |l| l.match?(MOD_DOC_LINE) }

          [Violation.new(path, 1, "missing_module_doc", File.basename(path))]
        end
      end
    end
  end
end
