# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineProfiling
      # The `Formula` and `Bound` rows of the `Profile` aggregate, as hashes keyed by setting. They
      # come from the booted IR, or from the bluebook file as text for a launcher that boots nothing
      # (as {Driving::Resident::WorldCap} reads a world); one declaration answers both.
      module Rows
        # The bluebook that declares the rows, relative to `lib/hecks`.
        FILE = File.expand_path("../../machine_profile/machine_profile.bluebook", __dir__)

        # A `member` line that names a setting.
        MEMBER = /\A\s*member setting:/

        # One `member` line's `name: value` pairs.
        PAIR = /(\w+):\s*("[^"]*"|-?[\d.]+)/

        module_function

        # @param aggregate [Bluebook::Aggregate] `Profile`
        # @return [Hash{Symbol => Hash{String => Hash}}] `formulas` and `bounds`, each by setting
        def of(aggregate)
          { formulas: keyed(members(aggregate, "Formula")), bounds: keyed(members(aggregate, "Bound")) }
        end

        # @param path [String] the bluebook file
        # @return [Hash{Symbol => Hash{String => Hash}}] the same rows, read from the file's text
        def from_file(path = FILE)
          lines = File.readlines(path).grep(MEMBER)
          rows = lines.map { |line| line.scan(PAIR).to_h { |key, raw| [key.to_sym, value(raw)] } }
          { formulas: keyed(rows.select { |row| row.key?(:measure) }), bounds: keyed(rows.select { |row| row.key?(:least) }) }
        end

        def members(aggregate, name)
          shape = aggregate.value_objects.find { |object| object.hecks_name == name }
          Array(shape&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
        end

        def keyed(rows) = rows.to_h { |row| [row[:setting], row] }

        def value(raw) = raw.start_with?('"') ? raw.delete('"') : Float(raw)
      end
    end
  end
end
