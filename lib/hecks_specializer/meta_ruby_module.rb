# lib/hecks_specializer/meta_ruby_module.rb
# [antibody-exempt: lib/hecks_specializer/meta_ruby_module.rb — generator, not generated]
#
# Hecks::Specializer::MetaRubyModule — Phase C PC-5.
#
# Fifth meta-specializer. Emits a top-level loader-module file from
# RubyModule + ModuleConstant + ModuleClassMethod + InnerModule
# fixture rows. Pilot target: lib/hecks_specializer.rb — the loader
# every specializer target registers against.
#
# Emission pipeline (verbatim concatenation):
#
#   1. doc_snippet verbatim  + blank line
#   2. outer_requires as "require "X"\n" lines + blank line
#   3. "module Hecks\n  module Specializer\n"
#   4. module-level constants (with optional pre-constant doc, blank
#      line before a doc-bearing constant when not the first)
#   5. class << self block (6-space indent inside, blank-line-separated
#      methods, optional pre-method doc comments)
#   6. inner modules (with pre-module doc, verbatim methods_block_snippet
#      inside, 4-space indent module/end)
#   7. module close ("  end\nend\n")
#   8. optional autoload block: blank + autoload_doc + Dir[...] loop
#
# Everything else than structure comes from .rb.frag snippets read
# raw. The meta-specializer owns only the scaffolding.
#
# Subclasses override `self.target_module_name` to pick which RubyModule
# row to emit for. Default (nil) picks the first row — kept simple for
# the PC-5 pilot, which ships with a single row (Hecks::Specializer).
#
# Shape limitation (deliberate): inner modules store their whole body
# as a single methods_block_snippet. Adequate for Target's 3-method
# mixin; a future pass may split into structured RubyMethod rows if
# a second inner module appears.

module Hecks
  module Specializer
    class MetaRubyModule
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/ruby_module_shape/fixtures/ruby_module_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer.rb")

      # Which RubyModule fixture row to emit for. Subclasses override
      # to pick a different row. Default (nil) picks the first row.
      def self.target_module_name
        nil
      end

      def emit
        mod = pick_module
        [
          emit_doc(mod),
          emit_outer_requires(mod),
          emit_module_open(mod),
          emit_outer_constants(mod),
          emit_class_methods_block(mod),
          emit_inner_modules(mod),
          emit_module_close(mod),
          emit_autoload_block(mod),
        ].join
      end

      private

      def pick_module
        rows = by_aggregate("RubyModule")
        name = self.class.target_module_name
        row = name ? rows.find { |r| r["attrs"]["name"] == name } : rows.first
        raise "no RubyModule row matching #{name.inspect}" unless row
        row
      end

      # Doc block — read verbatim (ends with "\n"). Append one more
      # "\n" to open a blank line before the requires block.
      def emit_doc(mod)
        File.read(REPO_ROOT.join(mod["attrs"]["doc_snippet"])) + "\n"
      end

      # require "X" lines, one per outer_requires entry. Empty list =
      # no lines and no trailing blank.
      def emit_outer_requires(mod)
        libs = mod["attrs"]["outer_requires"].to_s.split(",").map(&:strip).reject(&:empty?)
        return "" if libs.empty?
        libs.map { |l| "require \"#{l}\"\n" }.join + "\n"
      end

      # "module Hecks\n  module Specializer\n" — nests the dotted name.
      def emit_module_open(mod)
        segments = mod["attrs"]["name"].split("::")
        segments.each_with_index.map { |s, i| "#{"  " * i}module #{s}\n" }.join
      end

      # Module-level constants, sorted by order, indented to constant
      # depth (2-space * segments). Each constant with a doc_snippet
      # gets the doc read verbatim before the assignment, with a
      # leading blank line UNLESS it's the first constant.
      def emit_outer_constants(mod)
        constants = constants_for(mod)
        return "" if constants.empty?
        indent = constant_indent(mod)
        out = +""
        constants.each_with_index do |c, i|
          a = c["attrs"]
          if a["doc_snippet"].to_s.empty?
            out << "#{indent}#{a["name"]} = #{a["value_expr"]}\n"
          else
            out << "\n" unless i == 0
            out << File.read(REPO_ROOT.join(a["doc_snippet"]))
            out << "#{indent}#{a["name"]} = #{a["value_expr"]}\n"
          end
        end
        out
      end

      # The class << self ... end block. Blank line before, then
      # "    class << self\n", then each method (blank-separated) at
      # 6-space indent, then "    end\n".
      def emit_class_methods_block(mod)
        methods = methods_for(mod)
        return "" if methods.empty?
        indent = constant_indent(mod) # "    " for a 2-segment module
        parts = ["\n", "#{indent}class << self\n"]
        methods.each_with_index do |m, i|
          parts << "\n" unless i == 0
          parts << emit_class_method(m, indent)
        end
        parts << "#{indent}end\n"
        parts.join
      end

      def emit_class_method(method, module_indent)
        a = method["attrs"]
        def_indent = module_indent + "  " # inside class << self
        sig = a["signature"].to_s.empty? ? "def #{a["name"]}" : "def #{a["name"]}(#{a["signature"]})"
        doc = a["doc_snippet"].to_s.empty? ? "" : File.read(REPO_ROOT.join(a["doc_snippet"]))
        body = File.read(REPO_ROOT.join(a["body_snippet"]))
        "#{doc}#{def_indent}#{sig}\n#{body}#{def_indent}end\n"
      end

      # Inner mixin modules. Blank line before, then doc, then
      # "    module Name\n", then verbatim methods block, then "    end\n".
      def emit_inner_modules(mod)
        inners = by_aggregate("InnerModule")
                   .select { |i| i["attrs"]["parent_module"] == mod["attrs"]["name"] }
                   .sort_by { |i| i["attrs"]["order"].to_i }
        return "" if inners.empty?
        indent = constant_indent(mod)
        inners.map do |i|
          a = i["attrs"]
          doc = a["doc_snippet"].to_s.empty? ? "" : File.read(REPO_ROOT.join(a["doc_snippet"]))
          body = File.read(REPO_ROOT.join(a["methods_block_snippet"]))
          "\n#{doc}#{indent}module #{a["name"]}\n#{body}#{indent}end\n"
        end.join
      end

      # Close every module segment opened by emit_module_open, bottom-up.
      def emit_module_close(mod)
        depth = mod["attrs"]["name"].split("::").length
        (0...depth).to_a.reverse.map { |i| "#{"  " * i}end\n" }.join
      end

      # Trailing `Dir[File.expand_path(<glob>, <base>)].sort.each ...`
      # loop. Empty autoload_glob skips the whole block. Leading blank
      # line separates from the closed module.
      def emit_autoload_block(mod)
        glob = mod["attrs"]["autoload_glob"].to_s
        return "" if glob.empty?
        base = mod["attrs"]["autoload_base"].to_s
        doc_path = mod["attrs"]["autoload_doc_snippet"].to_s
        doc = doc_path.empty? ? "" : File.read(REPO_ROOT.join(doc_path))
        loop_block = "Dir[File.expand_path(\"#{glob}\", #{base})].sort.each do |path|\n  require path\nend\n"
        "\n#{doc}#{loop_block}"
      end

      def constants_for(mod)
        by_aggregate("ModuleConstant")
          .select { |c| c["attrs"]["module_name"] == mod["attrs"]["name"] }
          .sort_by { |c| c["attrs"]["order"].to_i }
      end

      def methods_for(mod)
        by_aggregate("ModuleClassMethod")
          .select { |m| m["attrs"]["module_name"] == mod["attrs"]["name"] }
          .sort_by { |m| m["attrs"]["order"].to_i }
      end

      def constant_indent(mod)
        "  " * mod["attrs"]["name"].split("::").length
      end
    end

    register :meta_ruby_module, MetaRubyModule
  end
end
