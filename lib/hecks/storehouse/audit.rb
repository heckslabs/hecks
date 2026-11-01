module Hecks
  module Storehouse
    # The bus's own JSONL audit log: writing a line for each dispatch, query and state call, and
    # reading it back as a tail or as the events it announced. Extended onto `Storehouse`.
    module Audit
      # The caller-supplied fields of an audit line, in the order the line spells them.
      AUDIT_FIELDS = %i[verb summary source role actor_id surface].freeze

      # A character a log file's name may not carry.
      UNSAFE_NAME_CHARACTER = /[^A-Za-z0-9_-]/

      # The boundary between a lowercase or digit character and an uppercase one, where a
      # CamelCase word takes an underscore.
      CAMEL_CASE_BOUNDARY = /([a-z\d])([A-Z])/

      # The last segment of a qualified constant name, such as `TypeMismatch` in `Runtime::TypeMismatch`.
      UNQUALIFIED_NAME = /[^:]+\z/

      # Kept under Hecks::CacheDir, not the domain directory (part of the domain's
      # own state) or the gem directory (read-only once installed).
      # :nodoc:
      def log_root = Hecks::CacheDir.path("storehouse")

      # :nodoc:
      def log_path(domain_name)
        File.join(log_root, "#{domain_name.to_s.gsub(UNSAFE_NAME_CHARACTER, "_")}.jsonl")
      end

      # Never fails a real call because its own audit log couldn't be written —
      # a full disk silences follow, not the dispatch/query/state call itself.
      #
      # @param entry [Hash] the line's `verb:`, `summary:`, `source:`, `role:` and `actor_id:`
      # :nodoc:
      def record!(domain_name, tool:, outcome:, **entry)
        return unless domain_name

        FileUtils.mkdir_p(log_root)
        File.open(log_path(domain_name), "a") { |f| f.puts(JSON.generate(audit_line(tool, outcome, entry))) }
      rescue StandardError
        nil
      end

      # One audit line as a hash: when, the tool, the caller's fields, the outcome's fields, then
      # the call's duration and refusal kind, with absent values left out.
      # :nodoc:
      def audit_line(tool, outcome, entry)
        fields = AUDIT_FIELDS.to_h { |field| [field, entry[field]] }
        { time: Time.now.utc.iso8601, tool: tool, **fields, **outcome.slice(:ok, :id, :error, :events),
          **entry.slice(:duration_ms, :refusal) }.compact
      end

      # Whole milliseconds since `started`, a CLOCK_MONOTONIC reading.
      # :nodoc:
      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end

      # The refusal's class as a snake_case kind, such as `type_mismatch`.
      # :nodoc:
      def refusal_kind(error)
        snake_case(error.class.name[UNQUALIFIED_NAME])
      end

      # The word with an underscore at each CamelCase boundary, in lowercase.
      # :nodoc:
      def snake_case(word) = word.gsub(CAMEL_CASE_BOUNDARY, '\\1_\\2').downcase

      # Tails this bus's own dispatch/query/state audit log — a pull-based
      # substitute for a push subscription, since a stdio server answers one
      # request at a time with no channel to push through.
      #
      # @param runtime [Runtime::Registry] the booted domain to tail
      # @param limit [Integer, #to_i] how many recent log entries to return
      # @return [Hash] :ok, :domain, :entries; or the refused shape
      def follow(runtime:, limit: 20)
        bluebook = bluebook_for(runtime)
        entries  = log_lines(bluebook.name).last([limit.to_i, 1].max)

        ok(domain: bluebook.name, entries: entries)
      rescue *refusal_classes => e
        refused(e)
      end

      # :nodoc:
      def log_lines(domain_name)
        path = log_path(domain_name)
        return [] unless File.exist?(path)

        File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
      end

      # What actually happened, with payloads, to one aggregate or record — read
      # off this bus's own audit log (a dispatch's announced events), not a full
      # event-sourcing replay. aggregate: narrows the search; id: (requires
      # aggregate:) narrows further to one record.
      #
      # @param runtime [Runtime::Registry] the booted domain to search
      # @param aggregate [String, Symbol, nil] narrows the search to one aggregate
      # @param id [String, Object, nil] narrows further to one record; requires aggregate
      # @param limit [Integer, #to_i, nil] how many recent matching events to
      #   return; nil returns every one found
      # @return [Hash] :ok, :domain, :events; or the refused shape
      # @raise [Runtime::TypeMismatch] if id is given without aggregate
      def events(runtime:, aggregate: nil, id: nil, limit: nil)
        if id && !aggregate
          raise Runtime::TypeMismatch, "id: requires aggregate: too — an id alone is not unique across aggregates"
        end

        bluebook = bluebook_for(runtime)
        fqn      = aggregate ? "#{bluebook.name}::#{aggregate_ir!(bluebook, aggregate).hecks_name}" : nil

        ok(domain: bluebook.name, events: matching_events(bluebook, fqn, id, limit))
      rescue *refusal_classes => e
        refused(e)
      end

      # :nodoc:
      def matching_events(bluebook, fqn, id, limit)
        found = log_lines(bluebook.name).filter_map { |entry| entry_events(entry, fqn, id) }.flatten(1)
        limit ? found.last(limit.to_i) : found
      end

      # :nodoc:
      def entry_events(entry, fqn, id)
        return unless entry[:tool] == "dispatch" && entry[:ok] && entry[:events]
        return unless targets?(entry, fqn, id)

        entry[:events].map { |event| event.merge(time: entry[:time], verb: entry[:verb], id: entry[:id]) }
      end

      # @return [Boolean] whether the audit entry is about the aggregate and record asked for
      def targets?(entry, fqn, id)
        return false if fqn && !entry[:verb].to_s.start_with?("#{fqn}.")

        !(id && entry[:id] != id)
      end
    end
  end
end
