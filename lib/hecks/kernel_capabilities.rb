# frozen_string_literal: true

require_relative "projection_files"

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
      lines = rows.map do |row|
        "#{row.present ? 'OK  ' : 'MISS'}  #{row.path.delete_prefix(prefix)}  (#{row.source}: #{row.name.inspect})"
      end
      missing = rows.reject(&:present)
      return [lines.join("\n"), coverage_verdict(rows.size), true] if missing.empty?

      gaps = missing.map { |row| "  #{row.path.delete_prefix(prefix)}" }
      head = "#{missing.size} capability file(s) missing — the grammar admits these but no " \
             "hand-written Rust interpretation exists for them yet:"
      [lines.join("\n"), [head, *gaps].join("\n"), false]
    end

    # @param count [Integer] how many capabilities there are
    # @return [String] the clean verdict
    def coverage_verdict(count)
      "#{count}/#{count} kernel capability files present — every attribute shape and " \
        "expression-operator category the live Ruby grammar admits has a rust/src/kernel/ file " \
        "at its conventional path."
    end

    # @param name [String, Symbol] a snake_case capability name
    # @return [String] the PascalCase Rust variant
    def pascal(name)
      name.to_s.split("_").map { |part| part[0].upcase + part[1..] }.join
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

    # @return [String] the whole `attribute_shapes/mod.rs`
    def shapes_module
      header = <<~HEADER.strip
        // Ground truth: Hecks::Runtime::Value::Coercion::SHAPES
        // (lib/hecks/runtime/value/coercion.rb) — the four branches
        // `for_attribute` itself takes, read directly rather than
        // re-derived here.
      HEADER
      render(header: header, enum_name: "AttributeShape", names: Hecks::Runtime::Value::Coercion::SHAPES,
             doc_line: "Coercion::SHAPES")
    end

    # @return [String] the whole `expression_operators/mod.rs`
    def operators_module
      header = <<~HEADER.strip
        // Ground truth: Hecks::Grammar.admitted_operators (lib/hecks/
        // grammar.rb), the SAME live-booted call hecks project_expression_tables
        // uses — grouped by the `category` field Evaluator::PROJECTION already
        // partitions comparison operators by (evaluator.rb).
      HEADER
      render(header: header, enum_name: "OperatorCategory", names: operator_categories,
             doc_line: "Grammar.admitted_operators's own `category` field")
    end

    # Renders one capability module: `pub mod` lines, the enum, and its `ALL`.
    #
    # @param header [String] the ground-truth comment
    # @param enum_name [String] `AttributeShape` or `OperatorCategory`
    # @param names [Array<String>] the capabilities, in declaration order
    # @param doc_line [String] where the capabilities are declared
    # @return [String] the Rust source
    def render(header:, enum_name:, names:, doc_line:)
      shapes   = enum_name == "AttributeShape"
      variants = names.map { |name| "    #{pascal(name)}," }.join("\n")
      mods     = names.map { |name| "pub mod #{name};" }.join("\n")
      arms     = names.map { |name| "            #{enum_name}::#{pascal(name)} => #{name.to_s.inspect}," }.join("\n")
      all      = names.map { |name| "#{enum_name}::#{pascal(name)}" }.join(", ")

      <<~RUST
        // GENERATED by hecks project_kernel_capabilities from #{doc_line}.
        // Do not hand-edit — re-run hecks project_kernel_capabilities instead.
        //
        #{header}

        #{mods}

        /// One variant per real #{shapes ? 'attribute shape' : 'expression-operator category'} the Ruby
        /// grammar admits, in the order #{doc_line} declares them. Every match
        /// over this enum in the kernel (rust/src/kernel/expr.rs) is written
        /// WITHOUT a wildcard `_ =>` arm — see expr.rs's own header for why:
        /// a wildcard here would let a newly-admitted capability compile
        /// silently into a router that never calls the new file this same
        /// regeneration adds a `pub mod` line for above.
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum #{enum_name} {
        #{variants}
        }

        impl #{enum_name} {
            /// The `rust/src/kernel/#{shapes ? 'attribute_shapes' : 'expression_operators'}/<name>.rs` file this
            /// variant names — `hecks measure_kernel_coverage`'s own existence
            /// check reads this, so the file-name spelling here is the ONE
            /// place that ever needs to change if a name is renamed.
            pub fn module_name(&self) -> &'static str {
                match self {
        #{arms}
                }
            }

            pub const ALL: &'static [#{enum_name}] = &[#{all}];
        }
      RUST
    end
  end
end
