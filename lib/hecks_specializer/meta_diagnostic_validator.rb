# lib/hecks_specializer/meta_diagnostic_validator.rb
#
# Hecks::Specializer::MetaDiagnosticValidator — Phase C PC-2.
#
# First meta-specializer that regenerates a FULL Ruby class (not just
# a thin subclass shell). Reads RubyClass + RubyMethod (+ optional
# RubyConstant) fixture rows from diagnostic_validator_meta_shape.fixtures
# and emits lib/hecks_specializer/<target>.rb byte-identical.
#
# Emission pipeline:
#   1. doc block (from RubyClass.doc_snippet, verbatim)
#   2. module nesting open (from RubyClass.module_path)
#   3. class declaration + include lines
#   4. constants (if any RubyConstant rows match class_name), sorted
#      by order, each preceded/separated by a blank line
#   5. blank line
#   6. public methods (RubyMethod rows with visibility=public) in order
#   7. blank line + "private" + blank line
#   8. private methods in order
#   9. class close
#  10. IF register_target_name non-empty: blank line + register call
#      at class-close depth (inside the innermost module)
#  11. module nesting close (ends)
#
# Method bodies come from .rb.frag snippets, read raw. The specializer
# only arranges the skeleton; bodies are the author's Ruby.
#
# Subclasses override `self.target_class_name` to pick which RubyClass
# row to emit for. Default picks the first row — kept for the pilot
# (DiagnosticValidator) which was the sole row when PC-2 landed.
#
# Scope: the base class diagnostic_validator.rb (148 LoC) and
# validator_warnings.rb (113 LoC). Design generalizes — PC-3 (driver)
# and PC-4 (fixed-point of meta_subclass itself) should reuse this
# pattern with different RubyClass rows.

module Hecks
  module Specializer
    class MetaDiagnosticValidator
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/diagnostic_validator_meta_shape/fixtures/diagnostic_validator_meta_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/diagnostic_validator.rb")

      # Which RubyClass fixture row to emit for. Subclasses override
      # to pick a different row. Default (nil) picks the first row.
      def self.target_class_name
        nil
      end

      def emit
        klass = pick_class
        methods = by_aggregate("RubyMethod")
                    .select { |m| m["attrs"]["class_name"] == klass["attrs"]["name"] }
                    .sort_by { |m| m["attrs"]["order"].to_i }
        public_methods = methods.select { |m| m["attrs"]["visibility"] == "public" }
        private_methods = methods.select { |m| m["attrs"]["visibility"] == "private" }

        [
          emit_doc(klass),
          emit_module_open(klass),
          emit_class_header(klass),
          emit_constants(klass),
          emit_methods(public_methods, blank_before_first: true),
          emit_private_section(private_methods),
          emit_module_close(klass),
        ].join
      end

      private

      def pick_class
        rows = by_aggregate("RubyClass")
        name = self.class.target_class_name
        row = name ? rows.find { |r| r["attrs"]["name"] == name } : rows.first
        raise "no RubyClass row matching #{name.inspect}" unless row
        row
      end

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
        register = emit_register_line(klass, depth)
        module_ends = (0...depth).to_a.reverse.map { |i| "  " * i + "end\n" }.join
        class_end + register + module_ends
      end

      # If the class registers itself as a specializer target (non-empty
      # register_target_name), emit the register call inside the innermost
      # module scope, separated by a blank line from the class close.
      def emit_register_line(klass, depth)
        name = klass["attrs"]["register_target_name"]
        return "" if name.nil? || name.empty?
        indent = "  " * depth
        "\n#{indent}register :#{name}, #{klass["attrs"]["name"]}\n"
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

      # Emit RubyConstant rows matching this class, sorted by order.
      # Each constant line is indented one step deeper than the class,
      # preceded by a blank line (separating from include block).
      # Empty if no constants — whole block collapses.
      def emit_constants(klass)
        constants = by_aggregate("RubyConstant")
                      .select { |c| c["attrs"]["class_name"] == klass["attrs"]["name"] }
                      .sort_by { |c| c["attrs"]["order"].to_i }
        return "" if constants.empty?
        depth = klass["attrs"]["module_path"].empty? \
                  ? 0 : klass["attrs"]["module_path"].split("::").length
        indent = "  " * (depth + 1)
        lines = constants.map do |c|
          a = c["attrs"]
          "#{indent}#{a["name"]} = #{a["value_expr"]}\n"
        end.join
        "\n#{lines}"
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

    # Phase C PC-2 extension — second full Ruby class retirement.
    # Emits lib/hecks_specializer/validator_warnings.rb from the
    # ValidatorWarnings RubyClass row in the same shape. Adds two
    # features the base exercised for the first time:
    #   - RubyConstant rows (SHAPE, TARGET_RS at class-body top)
    #   - register_target_name ("validator_warnings")
    class MetaValidatorWarnings < MetaDiagnosticValidator
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/validator_warnings.rb")
      def self.target_class_name
        "ValidatorWarnings"
      end
    end

    register :meta_validator_warnings, MetaValidatorWarnings
  end
end
