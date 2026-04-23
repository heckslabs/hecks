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
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/duplicate_policy.rb")

      # Which SpecializerSubclass fixture row to emit for. Subclasses
      # override to pick different rows.
      def self.row_target_name
        "duplicate_policy"
      end

      def emit
        rows = by_aggregate("SpecializerSubclass")
        row = rows.find { |r| r["attrs"]["target_name"] == self.class.row_target_name }
        raise "no SpecializerSubclass row for #{self.class.row_target_name.inspect}" unless row
        emit_row(row)
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

    # Second meta target — emits lib/hecks_specializer/lifecycle.rb
    # from the Lifecycle SpecializerSubclass row. Same pattern, different
    # row + output. Added in Phase C PC-1b.
    class MetaSubclassLifecycle < MetaSubclass
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/lifecycle.rb")
      def self.row_target_name
        "lifecycle"
      end
    end

    register :meta_subclass_lifecycle, MetaSubclassLifecycle
  end
end
