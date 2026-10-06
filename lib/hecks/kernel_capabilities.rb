# frozen_string_literal: true

require_relative "projection_files"
require_relative "kernel_capabilities/templates"

module Hecks
  # The capability enums the hand-written Rust kernel is matched against, and the check that every
  # capability the Ruby grammar admits has its hand-written file.
  #
  # The `pub mod` roster and the enum of `rust/src/kernel/attribute_shapes/mod.rs` and
  # `rust/src/kernel/expression_operators/mod.rs` are generated; the `<name>.rs` files beside them
  # are hand-written, so a grammar change can leave a `pub mod` naming a file nobody has written.
  # Ground truth is `Coercion::SHAPES` and `Grammar.admitted_operators`, never a copied list.
  # Query comparators are one flat hand-maintained file with no per-variant files to check.
  module KernelCapabilities
    # One capability a hand-written kernel file should exist for.
    #
    # @!attribute [r] name
    #   @return [String] the capability's name
    # @!attribute [r] path
    #   @return [String] where its file conventionally stands
    # @!attribute [r] present
    #   @return [Boolean] whether the file exists
    # @!attribute [r] source
    #   @return [String] where the capability is declared
    Row = Struct.new(:name, :path, :present, :source)

    extend Templates

    module_function

    # Renders both capability modules without writing them.
    #
    # @param root [String] the checkout
    # @return [ProjectionFiles::Result] each `mod.rs`, and nothing stale
    def build(root: ProjectionFiles::ROOT)
      require "hecks"
      require "hecks/grammar"
      require "hecks/runtime/value/coercion"
      kernel = File.join(root, "rust/src/kernel")
      content = {
        File.join(kernel, "attribute_shapes/mod.rs")     => shapes_module,
        File.join(kernel, "expression_operators/mod.rs") => operators_module
      }
      ProjectionFiles::Result.new(content, [])
    end

    # Writes the capability modules.
    #
    # @param root [String] the checkout
    # @return [Array<String>] one `wrote <path>` line for each file
    def write(root: ProjectionFiles::ROOT)
      build(root: root).content.map { |path, text| ProjectionFiles.write_atomically(path, text) }
    end

    # Checks every capability the live grammar admits against the kernel's files.
    #
    # @param root [String] the checkout
    # @return [Array<Row>] one row for each attribute shape and expression-operator category
    def coverage(root: ProjectionFiles::ROOT)
      require "hecks"
      require "hecks/grammar"
      require "hecks/runtime/value/coercion"
      check(root, "attribute_shapes", Hecks::Runtime::Value::Coercion::SHAPES, "Coercion::SHAPES") +
        check(root, "expression_operators", operator_categories,
              "Grammar.admitted_operators's own category field")
    end

    # The coverage check as text: one line for each capability, then a verdict.
    #
    # @param root [String] the checkout
    # @return [Array(String, String, Boolean)] the lines of the check, the closing verdict (the
    #   complaint, when a file is missing), and whether every file is present
    def coverage_report(root: ProjectionFiles::ROOT)
      rows = coverage(root: root)
      prefix = "#{root}/"
      lines = rows.map { |row| report_line(row, prefix) }.join("\n")
      missing = rows.reject(&:present)
      return [lines, coverage_verdict(rows.size), true] if missing.empty?

      [lines, missing_verdict(missing, prefix), false]
    end

    # @return [String] one capability's line: whether its file is there, where, and why it is wanted
    def report_line(row, prefix)
      "#{row.present ? "OK  " : "MISS"}  #{row.path.delete_prefix(prefix)}  (#{row.source}: #{row.name.inspect})"
    end

    # @param missing [Array<Row>] the capabilities with no file
    # @param prefix [String] the checkout's root, with its trailing slash
    # @return [String] the complaint naming each missing file
    def missing_verdict(missing, prefix)
      gaps = missing.map { |row| "  #{row.path.delete_prefix(prefix)}" }
      head = "#{missing.size} capability file(s) missing — the grammar admits these but no " \
             "hand-written Rust interpretation exists for them yet:"
      [head, *gaps].join("\n")
    end

    # @param count [Integer] how many capabilities there are
    # @return [String] the clean verdict
    def coverage_verdict(count)
      "#{count}/#{count} kernel capability files present — every attribute shape and " \
        "expression-operator category the live Ruby grammar admits has a rust/src/kernel/ file " \
        "at its conventional path."
    end

    # `category` in first-appearance order over the admission ledger, never alphabetized, so a
    # re-run does not reshuffle variants.
    #
    # @return [Array<String>] the expression-operator categories
    def operator_categories
      Hecks::Grammar.admitted_operators.map { |op| op[:category] }.uniq
    end

    # @param root [String] the checkout
    # @param category_dir [String] the directory below `rust/src/kernel/`
    # @param names [Array<String>] the capabilities to look for
    # @param source [String] where they are declared
    # @return [Array<Row>] a row for each
    def check(root, category_dir, names, source)
      names.map do |name|
        path = File.join(root, "rust/src/kernel", category_dir, "#{name}.rs")
        Row.new(name, path, File.file?(path), source)
      end
    end
  end
end
