# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # Which bluebook releases one deploy changes: two `hecks package.verify` outputs compared by
    # bluebook name, version, shape and digest.
    #
    # A bluebook is added, removed, re-versioned (a new era when its shape changed too), or has the
    # same version with different content (a vendored copy edited or re-tagged). The comparison is
    # pure; reading the running image's label out of a registry is not done here.
    class BluebookReport
      ROW = "    %-24s %s"

      # @param old_json [String] the running side's `package.verify` output
      # @param new_json [String] the side about to ship
      # @param label [String] what the old side is called in the heading
      # @raise [JSON::ParserError] when either side is not JSON
      def initialize(old_json, new_json, label: "old")
        @old = JSON.parse(old_json)
        @new = JSON.parse(new_json)
        @label = label
        @changed = false
        @era = false
      end

      # @return [Boolean] whether any bluebook was added, removed, re-versioned or changed
      def changed?
        text
        @changed
      end

      # @return [String] the heading, one line per bluebook, the commits, and a note on a new era
      def text
        @text ||= build.join("\n")
      end

      private

      def build
        old_books = @old.fetch("bluebooks", {})
        new_books = @new.fetch("bluebooks", {})
        lines = ["==> bluebooks in this deploy (#{@label} -> this build)"]
        (old_books.keys | new_books.keys).sort.each { |name| lines << row(name, old_books[name], new_books[name]) }
        lines << commits
        lines << "    no bluebook changes." unless @changed
        lines << "    NOTE: a shape change mints a new era when the domain boots on it." if @era
        lines
      end

      def row(name, old, new)
        return mark(name, "ADDED #{new["version"]}") if old.nil?
        return mark(name, "REMOVED (was #{old["version"]})") if new.nil?
        return reversioned(name, old, new) if old["version"] != new["version"]
        return same_version_changed(name, old, new) if old["digest"] != new["digest"]

        format(ROW, name, "#{new["version"]}   unchanged")
      end

      def same_version_changed(name, old, new)
        mark(name, "#{new["version"]}   SAME VERSION, DIFFERENT CONTENT (digest #{old["digest"][0, 8]} -> " \
                   "#{new["digest"][0, 8]}); a vendored copy was edited or re-tagged")
      end

      def reversioned(name, old, new)
        line = "#{old["version"]} -> #{new["version"]}"
        if old["shape"] != new["shape"]
          line += "   shape #{shape(old)} -> #{shape(new)}   NEW ERA (its translation edge must already be in " \
                  "bluebook/translations/)"
          @era = true
        end
        mark(name, line)
      end

      def mark(name, text)
        @changed = true
        format(ROW, name, text)
      end

      def shape(book) = book["shape"].map { |entry| entry.split.last }.join(", ")

      def commits
        old = @old.dig("built_from", "commit") || "?"
        new = @new.dig("built_from", "commit") || "?"
        dirty = @new.dig("built_from", "dirty") ? " (uncommitted changes)" : ""
        "    built from #{old[0, 7]} -> #{new[0, 7]}#{dirty}"
      end
    end
  end
end
