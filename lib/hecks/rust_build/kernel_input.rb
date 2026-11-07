# frozen_string_literal: true

require "json"
require_relative "../rust_build"

module Hecks
  module RustBuild
    # The stdin a compiled domain binary reads: the steps to run, plus what the host would hand its
    # kernel from the domain's IR.
    #
    # The kernel has no IR of its own, so the facts a declaration reaches it with arrive as
    # top-level tables the Rust host builds from the domain's IR: `"defaults"`, a command's declared
    # argument defaults (`{ "Domain::Aggregate.Command" => { "attribute" => value } }`); `"needs"`,
    # the outside facts a command needs; and `"query_needs"`, the same for a query (kept apart: a
    # command and a query may share a qualified name). A harness that sends only `"steps"` would
    # leave the kernel refusing an argument Ruby fills, so every conformance caller builds its
    # input here.
    module KernelInput
      module_function

      # @param domain_path [String] the domain's directory; its basename names the generated module
      # @param steps [Array<Hash>] the steps to run
      # @param identity [Array<String>, nil] the ids the `identity_generation` port hands out, in
      #   order, to a reaction that mints a run key; the host's own port answers when omitted
      # @return [Hash{String => Object}] the input; each table is there only when it has an entry
      def build(domain_path, steps, identity: nil)
        input = { "steps" => steps }
        tables_for(domain_path).each { |name, table| input[name] = table unless table.empty? }
        input["identity"] = identity if identity
        input
      end

      # @param domain_path [String] the domain's directory
      # @param identity [Array<String>, nil] see {build}
      # @return [String] the input as JSON, ready for the binary's stdin
      def json(domain_path, steps, identity: nil) = JSON.generate(build(domain_path, steps, identity: identity))

      # Each command's declared defaults, entity commands included, read from the domain's
      # generated IR. An entity's commands sit under `Domain::Aggregate.Entity[.Entity].Command`.
      #
      # @param domain_path [String] the domain's directory
      # @return [Hash{String => Hash{String => Object}}] empty when the IR is absent or has none
      def defaults_for(domain_path) = tables_for(domain_path).fetch("defaults")

      # The three tables of one domain: `"defaults"`, `"needs"` and `"query_needs"`.
      #
      # @param domain_path [String] the domain's directory
      # @return [Hash{String => Hash}] each table, empty when the IR is absent or declares none
      def tables_for(domain_path)
        tables = { "defaults" => {}, "needs" => {}, "query_needs" => {}, "run_required" => [] }
        ir = generated_ir(domain_path) or return tables
        domain = ir["name"].to_s
        Array(ir["aggregates"]).each do |aggregate|
          collect(aggregate, "#{domain}::#{aggregate["name"]}", tables)
          tables["run_required"].concat(run_required_of(aggregate, "#{domain}::#{aggregate["name"]}"))
        end
        tables
      end

      # The verbs of an aggregate's own commands that take a required `run`: the ones a reaction
      # mints a key for when it names none (an entity's commands are not minted for).
      #
      # @param aggregate [Hash] an aggregate of the IR
      # @param prefix [String] its qualified name
      # @return [Array<String>] `Domain::Aggregate.Command` for each
      def run_required_of(aggregate, prefix)
        Array(aggregate["commands"]).select { |command| requires_run?(command) }
                                    .map { |command| "#{prefix}.#{command["name"]}" }
      end

      def requires_run?(command)
        Array(command["attributes"]).any? { |attribute| attribute["name"] == "run" && !attribute["optional"] }
      end

      # Adds what `node`'s commands and queries declare, then what each entity nested in it does,
      # under `prefix`.
      #
      # @param node [Hash] an aggregate or entity of the IR
      # @param prefix [String] the verb path down to `node`
      # @param tables [Hash] filled in place
      # @return [void]
      def collect(node, prefix, tables)
        Array(node["commands"]).each { |command| collect_command(command, "#{prefix}.#{command["name"]}", tables) }
        Array(node["queries"]).each { |query| collect_query(query, "#{prefix}.#{query["name"]}", tables) }
        Array(node["entities"]).each { |entity| collect(entity, "#{prefix}.#{entity["name"]}", tables) }
      end

      def collect_command(command, verb, tables)
        held = defaults_of(command)
        tables["defaults"][verb] = held unless held.empty?
        tables["needs"][verb] = needs_of(command) unless Array(command["needs"]).empty?
      end

      def defaults_of(command)
        Array(command["attributes"]).reject { |attribute| attribute["default"].nil? }
                                    .to_h { |attribute| [attribute["name"], attribute["default"]] }
      end

      def collect_query(query, verb, tables)
        tables["query_needs"][verb] = needs_of(query) unless Array(query["needs"]).empty?
      end

      # @param declaration [Hash] a command or query of the IR that declares `needs`
      # @return [Array<Hash>] each needed fact with the type of the argument of the same name
      def needs_of(declaration)
        Array(declaration["needs"]).map do |need|
          argument = Array(declaration["attributes"]).find { |attribute| attribute["name"] == need["fact"] }
          { "fact" => need["fact"], "type" => argument ? argument["type"].to_s : "" }
        end
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
