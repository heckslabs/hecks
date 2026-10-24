# frozen_string_literal: true

require_relative "../../tools"
require_relative "walker"
require "hecks/naming"

module Hecks
  module Tools
    module CommentStyle
      # The structural categories: the doc tags a public method carries and the shape of a long
      # class doc.
      module StructureChecks
        # A doc that opts out of the tag checks: private, no-doc, or a closing "(see ...)" pointer.
        TAGS_EXEMPT = /@api private|@private|:nodoc:|\(see (?:`[^`]+`|#\w)[^)]*\)\W*\z/m
        # The indent, hashes and one space that open a doc line.
        DOC_LINE_MARKER = /\A\s*#+\s?/
        # A `##` section heading inside a class doc.
        SECTION_HEADING = /\A#\s*##+ /

        private

        def structure_violations
          methods, types = structure
          methods.flat_map { |m| method_violations(m) } + types.flat_map { |t| long_doc_violations(t) }
        end

        def structure
          @structure ||= begin
            walker = Walker.new
            sexp = Ripper.sexp(@source)
            walker.walk(sexp, Walker::Scope.new([], :public)) if sexp
            [walker.methods, walker.types]
          end
        end

        def doc_above(line)
          block = []
          cursor = line - 1
          while (comment = @by_line[cursor]) && comment.full_line
            block.unshift(comment.text)
            cursor -= 1
          end
          block
        end

        def method_violations(method)
          return [] unless method.visibility == :public
          return [] unless CommentStyle.public_surface.include?(Hecks::Naming.demodulise(method.type_fqn))

          doc = doc_above(method.line).join("\n")
          return undocumented_violation(method) if doc.empty?
          return [] if doc.match?(TAGS_EXEMPT)

          tag_violations(method, doc)
        end

        def undocumented_violation(method)
          return [] if SELF_EVIDENT.include?(method.name)

          [Violation.new(path, method.line, "undocumented_method", "##{method.name}")]
        end

        def tag_violations(method, doc)
          param_violations(method, doc) + summary_violations(method, doc) + outcome_violations(method, doc)
        end

        def param_violations(method, doc)
          found = method.params.reject { |name| doc.match?(/@(?:param|option)\s+(?:\[[^\]\n]*\]\s*)?#{Regexp.escape(name)}\b/) }
                        .map { |name| violation(method, "missing_param", "lacks @param #{name}") }
          block = method.block_param
          if block && !doc.match?(/@yield|@param\s+(?:\[[^\]\n]*\]\s*)?#{Regexp.escape(block)}\b/)
            found << violation(method, "missing_param", "lacks @yield for &#{block}")
          end
          found
        end

        def summary_violations(method, doc)
          found = []
          found << violation(method, "missing_summary", "") if tags_only?(doc) && method.name != "initialize"
          if heading_lead?(doc)
            found << violation(method, "missing_summary",
                               "opens with a bold heading: add a verb-first lead sentence above it")
          end
          found
        end

        def outcome_violations(method, doc)
          found = []
          returns = method.name == "initialize" || method.name.end_with?("=") || doc.include?("@return")
          found << violation(method, "missing_return", "") unless returns
          found << violation(method, "missing_raise", "") if method.raises && !doc.include?("@raise")
          found
        end

        def tags_only?(doc)
          lead_line(doc).start_with?("@")
        end

        # A bold heading is a paragraph title, not a sentence about the method.
        def heading_lead?(doc)
          lead_line(doc).start_with?("**")
        end

        def lead_line(doc)
          lines = doc.lines.map { |line| line.sub(DOC_LINE_MARKER, "").strip }
          lines.reject(&:empty?).first.to_s
        end

        def violation(method, category, detail)
          Violation.new(path, method.line, category, "##{method.name} #{detail}".strip)
        end

        def long_doc_violations(type)
          doc = doc_above(type.line)
          return [] if doc.length <= LONG_CLASS_DOC || doc.any? { |l| l.match?(SECTION_HEADING) }

          [Violation.new(path, type.line, "unstructured_class_doc", "#{type.fqn} (#{doc.length} lines)")]
        end
      end
    end
  end
end
