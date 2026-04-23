# lib/hecks_specializer/meta_subclass.rb
#
# Hecks::Specializer::MetaSubclass — Phase C PC-1 pilot.
#
# The meta-specializer. Reads SpecializerSubclass rows from
# specializer.fixtures and emits lib/hecks_specializer/<target>.rb
# (the Ruby subclass shells themselves).
#
# This is the FIRST self-referential specializer: its output lives
# under the same lib/hecks_specializer/ that holds the code reading
# it. PC-1's byte-identity test proves the specializer can regenerate
# (part of) itself — the pilot for the 2nd Futamura fixed point.
#
# Phase: C. Scope: 5 subclass shells (~15 LoC each); base class,
# driver, and fixed-point come in PC-2..PC-4.
#
# Usage differs from other targets because there's N output files,
# not one. Invoked via:
#   bin/specialize meta_subclass              # emits first-row target
#   bin/specialize meta_subclass --list       # list all rows
#   bin/specialize meta_subclass --name NAME  # emit specific row
#   bin/specialize meta_subclass --all        # emit every row to disk
#
# For golden-test purposes, :meta_subclass with no flags emits the
# first registered row (DuplicatePolicy) to stdout — consistent with
# how other targets behave and lets us gate byte-identity with the
# same assert_byte_identical helper.

require_relative "diagnostic_validator" # picks up Target mixin

module Hecks
  module Specializer
    class MetaSubclass
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/specializer/fixtures/specializer.fixtures")
      # TARGET_RS is the first-row target by default — the golden test
      # asserts byte-identity against this specific file. Other rows
      # emit via --name / --all flags.
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/duplicate_policy.rb")

      def emit(target_name: nil)
        rows = by_aggregate("SpecializerSubclass")
        row = if target_name
                rows.find { |r| r["attrs"]["target_name"] == target_name }
              else
                rows.first
              end
        raise "no SpecializerSubclass row#{target_name ? " for #{target_name}" : ""}" unless row
        emit_row(row)
      end

      def rows
        by_aggregate("SpecializerSubclass")
      end

      private

      # Emit one Ruby subclass file's contents. Template matches the
      # hand-written shell byte-for-byte: doc block, require_relative,
      # class body, register call.
      def emit_row(row)
        a = row["attrs"]
        doc_lines = a["module_doc"].split("\n").map do |line|
          line.empty? ? "#" : "# #{line}"
        end
        <<~RB
          # #{a["output_rb"]}
          #
          #{doc_lines.join("\n")}

          require_relative "diagnostic_validator"

          module Hecks
            module Specializer
              class #{a["class_name"]} < #{a["base_class"]}
                SHAPE = REPO_ROOT.join("#{a["shape_path"]}")
                TARGET_RS = REPO_ROOT.join("#{a["target_rs_path"]}")
              end

              register :#{a["target_name"]}, #{a["class_name"]}
            end
          end
        RB
      end
    end

    register :meta_subclass, MetaSubclass
  end
end
