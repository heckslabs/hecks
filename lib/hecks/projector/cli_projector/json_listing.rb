require "json"
require_relative "../../naming"

module Hecks
  module Projector
    module CliProjector
      # `hecks --json` and `hecks <module> --json` (ADR 0163, plan step 9): the same entries the
      # help lists, as JSON, so the MCP adapter, the docs and scripts read one projection. Each
      # entry is one command or query, with the call to type and the module it sits under.
      module JsonListing
        # The JSON document for the listing: one array of entries, in the order the help lists them.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose modules name each entry
        # @param commands [Hash{Symbol => Hash}] the projected command specs
        # @param questions [Hash{Symbol => Hash}] the projected query specs
        # @param options [Hash{Symbol => Object}] the listing's options: `:all` includes the
        #   internal entries; `:module` limits the entries to one module's name; `:everyday` names
        #   the calls the everyday section lists
        # @return [String] the JSON text
        def json_listing(bluebook, commands, questions, options)
          entries = [commands, questions].flat_map { |specs| json_entries(bluebook, specs, options) }
          JSON.generate(entries)
        end

        # The entries of one table the audience is shown, internal ones only with `:all`, and
        # limited to a module when one is named.
        def json_entries(bluebook, specs, options)
          shown = CliAudience.audience_specs(specs, options).reject { |_, spec| hidden?(spec, options) }
          entries = shown.map { |key, spec| json_entry(bluebook, spec, key, options) }
          entries.select { |entry| in_requested_module?(entry, options) }
        end

        # Whether an entry is internal and the listing leaves internal entries out.
        def hidden?(spec, options)
          spec[:internal] && !options[:all]
        end

        # Whether an entry sits in the module the listing was asked for, or in any when none was.
        def in_requested_module?(entry, options)
          options[:module].nil? || entry["module"] == Naming.snake(options[:module])
        end

        # One entry: its call, its qualified name, its verb, its kind, the module and aggregate it
        # sits under, its description, its audience, and whether it is in the everyday section.
        def json_entry(bluebook, spec, key, options)
          call = label(spec)
          {
            "call"     => call,
            "everyday" => Array(options[:everyday]).include?(key),
            "module"   => group_name(bluebook, spec),
            **entry_identity(spec),
            **entry_flags(spec)
          }
        end

        # What an entry is called: its call, qualified name, verb, kind and aggregate.
        def entry_identity(spec)
          {
            "name"      => spec[:command],
            "verb"      => spec[:short].to_s,
            "kind"      => spec[:kind].to_s,
            "aggregate" => spec[:group]
          }
        end

        # What an entry says about itself: its description, audience and whether it is internal.
        def entry_flags(spec)
          {
            "description" => spec[:summary].to_s,
            "audience"    => Array(spec[:audience]).map(&:to_s),
            "internal"    => spec[:internal] ? true : false
          }
        end
      end
    end
  end
end
