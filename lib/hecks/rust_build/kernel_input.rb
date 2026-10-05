# frozen_string_literal: true

require "json"
require_relative "../rust_build"

module Hecks
  module RustBuild
    # The stdin a compiled domain binary reads: the steps to run, plus the declared argument
    # defaults the host would hand its kernel.
    #
    # The kernel has no IR of its own, so a command's declared defaults reach it as a top-level
    # `"defaults"` table, `{ "Domain::Aggregate.Command" => { "attribute" => value } }`, the same
    # one the Rust host builds from the domain's IR. A harness that sends only `"steps"` would
    # leave the kernel refusing an argument Ruby fills, so every conformance caller builds its
    # input here.
    module KernelInput
      module_function

      # @param domain_path [String] the domain's directory; its basename names the generated module
      # @param steps [Array<Hash>] the steps to run
      # @return [Hash{String => Object}] the input; `"defaults"` is there only when one is declared
      def build(domain_path, steps)
        input = { "steps" => steps }
        defaults = defaults_for(domain_path)
        input["defaults"] = defaults unless defaults.empty?
        input
      end

      # @param domain_path [String] the domain's directory
      # @return [String] the input as JSON, ready for the binary's stdin
      def json(domain_path, steps) = JSON.generate(build(domain_path, steps))

      # Each command's declared defaults, entity commands included, read from the domain's
      # generated IR. An entity's commands sit under `Domain::Aggregate.Entity[.Entity].Command`.
      #
      # @param domain_path [String] the domain's directory
      # @return [Hash{String => Hash{String => Object}}] empty when the IR is absent or has none
      def defaults_for(domain_path)
        ir = generated_ir(domain_path) or return {}
        domain = ir["name"].to_s
        Array(ir["aggregates"]).each_with_object({}) do |aggregate, table|
          collect_defaults(aggregate, "#{domain}::#{aggregate['name']}", table)
        end
      end

      # Adds the defaults of `node`'s commands, then of each entity nested in it, under `prefix`.
      #
      # @param node [Hash] an aggregate or entity of the IR
      # @param prefix [String] the verb path down to `node`
      # @param table [Hash] filled in place
      # @return [void]
      def collect_defaults(node, prefix, table)
        Array(node["commands"]).each do |command|
          held = Array(command["attributes"]).reject { |attribute| attribute["default"].nil? }
                                             .to_h { |attribute| [attribute["name"], attribute["default"]] }
          table["#{prefix}.#{command['name']}"] = held unless held.empty?
        end
        Array(node["entities"]).each { |entity| collect_defaults(entity, "#{prefix}.#{entity['name']}", table) }
      end

      # @param domain_path [String] the domain's directory
      # @return [Hash, nil] the parsed generated IR, or nil when the domain has none
      def generated_ir(domain_path)
        feature = File.basename(domain_path.to_s.chomp("/")).downcase
        path = File.join(RustBuild.rust_dir, "src", "generated", feature, "ir.json")
        File.file?(path) ? JSON.parse(File.read(path)) : nil
      end
    end
  end
end
