# Hecks::CLI::VersionLogFormatter
#
# Formats version log entries with change summaries. Loads consecutive
# version pairs and diffs them to produce a one-line summary of changes
# between each version.
#
#   entries = Hecks::DomainVersioning.log(base_dir: ".")
#   lines = VersionLogFormatter.format(entries)
#   # => ["2.1.0  2026-04-01  +FreezeAccount command, +tags attribute", ...]
#
module Hecks
  class CLI < Thor
    # Hecks::CLI::VersionLogFormatter
    #
    # Formats version log entries with diff summaries between consecutive domain versions.
    #
    module VersionLogFormatter
      # Format log entries with change summaries.
      #
      # @param entries [Array<Hash>] from DomainVersioning.log
      # @return [Array<String>] formatted lines
      def self.format(entries)
        return [] if entries.empty?

        max_ver = entries.map { |e| e[:version].to_s.length }.max
        max_date = entries.map { |e| e[:tagged_at].to_s.length }.max

        entries.each_with_index.map do |entry, i|
          older = entries[i + 1]
          summary = older ? summarize(older[:path], entry[:path]) : "Initial snapshot"
          "%-#{max_ver}s  %-#{max_date}s  %s" % [entry[:version], entry[:tagged_at], summary]
        end
      end

      # Produce a one-line summary of changes between two snapshot files.
      #
      # @param old_path [String] path to older snapshot
      # @param new_path [String] path to newer snapshot
      # @return [String] summary line
      def self.summarize(old_path, new_path)
        old_domain = load_snapshot(old_path)
        new_domain = load_snapshot(new_path)
        return "?" unless old_domain && new_domain

        changes = Hecks::Migrations::DomainDiff.call(old_domain, new_domain)
        return "No changes" if changes.empty?

        labels = changes.first(3).map { |c| short_label(c) }
        extra = changes.size > 3 ? ", +#{changes.size - 3} more" : ""
        labels.join(", ") + extra
      end

      # @param path [String] snapshot file path
      # @return [Hecks::BluebookModel::Domain, nil]
      def self.load_snapshot(path)
        return nil unless File.exist?(path)
        Kernel.load(path)
        Hecks.last_domain
      end

      # Short label for a single change.
      #
      # @param change [Hecks::Migrations::DomainDiff::Change]
      # @return [String]
      def self.short_label(change)
        case change.kind
        when :add_command    then "+#{change.details[:name]} command"
        when :remove_command then "-#{change.details[:name]} command"
        when :add_attribute  then "+#{change.details[:name]} attribute"
        when :remove_attribute then "-#{change.details[:name]} attribute"
        when :add_aggregate  then "+#{change.aggregate} aggregate"
        when :remove_aggregate then "-#{change.aggregate} aggregate"
        else change.kind.to_s.sub("_", " ")
        end
      end
    end
  end
end
