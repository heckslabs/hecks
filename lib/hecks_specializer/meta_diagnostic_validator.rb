# lib/hecks_specializer/meta_diagnostic_validator.rb
#
# Hecks::Specializer::MetaDiagnosticValidator — Phase C PC-2.
#
# First meta-specializer that regenerates a FULL Ruby class (not just
# a thin subclass shell). Reads RubyClass + RubyMethod fixture rows
# from diagnostic_validator_meta_shape.fixtures and emits
# lib/hecks_specializer/diagnostic_validator.rb byte-identical.
#
# Emission pipeline:
#   1. doc block (from RubyClass.doc_snippet, verbatim)
#   2. module nesting open (from RubyClass.module_path)
#   3. class declaration + include lines
#   4. blank line
#   5. public methods (RubyMethod rows with visibility=public) in order
#   6. blank line + "private" + blank line
#   7. private methods in order
#   8. module nesting close (ends + ends)
#
# Method bodies come from .rb.frag snippets, read raw. The specializer
# only arranges the skeleton; bodies are the author's Ruby.
#
# Scope: the base class diagnostic_validator.rb (148 LoC). Design
# generalizes — PC-3 (driver) and PC-4 (fixed-point of meta_subclass
# itself) should reuse this pattern with different RubyClass rows.

module Hecks
  module Specializer
    class MetaDiagnosticValidator
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/diagnostic_validator_meta_shape/fixtures/diagnostic_validator_meta_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/diagnostic_validator.rb")

      def emit
        klass = by_aggregate("RubyClass").first or raise "no RubyClass row"
        methods = by_aggregate("RubyMethod")
                    .select { |m| m["attrs"]["class_name"] == klass["attrs"]["name"] }
                    .sort_by { |m| m["attrs"]["order"].to_i }
        public_methods = methods.select { |m| m["attrs"]["visibility"] == "public" }
        private_methods = methods.select { |m| m["attrs"]["visibility"] == "private" }

        [
          emit_doc(klass),
          emit_module_open(klass),
          emit_class_header(klass),
          emit_methods(public_methods, blank_before_first: true),
          emit_private_section(private_methods),
          emit_module_close(klass),
        ].join
      end

      private

      def emit_doc(klass)
        # Doc snippet ends with `\n`; add one more for blank-line separator
        # before the module nesting begins.
        File.read(REPO_ROOT.join(klass["attrs"]["doc_snippet"])) + "\n"
      end

      # Emit "module A\n  module B\n  ..." for each segment of module_path.
      # Empty module_path = no module nesting.
      def emit_module_open(klass)
        path = klass["attrs"]["module_path"]
        return "" if path.empty?
        segments = path.split("::")
        segments.each_with_index.map do |seg, i|
          "  " * i + "module #{seg}\n"
        end.join
      end

      def emit_module_close(klass)
        path = klass["attrs"]["module_path"]
        depth = path.empty? ? 0 : path.split("::").length
        class_end = "  " * depth + "end\n"
        module_ends = (0...depth).to_a.reverse.map { |i| "  " * i + "end\n" }.join
        class_end + module_ends
      end

      # Emit the class line + include lines. Indented to match nested
      # module depth.
      def emit_class_header(klass)
        a = klass["attrs"]
        depth = a["module_path"].empty? ? 0 : a["module_path"].split("::").length
        indent = "  " * depth
        class_line = a["base_class"].empty? \
                       ? "#{indent}class #{a["name"]}\n"
                       : "#{indent}class #{a["name"]} < #{a["base_class"]}\n"
        mixins = a["includes"].split(",").map(&:strip).reject(&:empty?)
        mixin_lines = mixins.map { |m| "#{indent}  include #{m}\n" }.join
        class_line + mixin_lines
      end

      # Emit a run of methods with correct spacing. Each method preceded
      # by a blank line (except maybe the first — controlled by flag).
      def emit_methods(methods, blank_before_first:)
        methods.each_with_index.map do |m, i|
          lead = (i == 0 && !blank_before_first) ? "" : "\n"
          lead + emit_method(m)
        end.join
      end

      def emit_private_section(private_methods)
        return "" if private_methods.empty?
        # Blank line, "private" (indented to method depth), blank line,
        # then each private method preceded by blank.
        indent = "      " # 3 levels of 2-space = 6 spaces (Hecks::Specializer::Class)
        "\n#{indent}private\n" + emit_methods(private_methods, blank_before_first: true)
      end

      def emit_method(method)
        a = method["attrs"]
        indent = "      " # 6 spaces: module → module → class
        sig = a["signature"].empty? ? "def #{a["name"]}" : "def #{a["name"]}(#{a["signature"]})"
        body = File.read(REPO_ROOT.join(a["body_snippet"]))
        "#{indent}#{sig}\n#{body}#{indent}end\n"
      end
    end

    register :meta_diagnostic_validator, MetaDiagnosticValidator
  end
end
