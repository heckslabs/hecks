# frozen_string_literal: true

require_relative "../memory"

module Hecks
  module Adapters
    class AdrFiles < Memory
      # The header of a decision record file: its `# Title` line and its status line, the only parts
      # of the file `Tickets::Adr` holds. Reading and rewriting it leaves every other line alone.
      #
      # A status line starts with a state of the Adr lifecycle, capitalised, then any prose the
      # author wrote: `**Status:** Accepted (owner, 2026-11-02). Date: 2026-11-02.` A superseded
      # record may name its successor right after the word: `**Status:** Superseded by [ADR 0180](0180-slug.md).`
      module Header
        module_function

        OPENING = 12
        STATUS_LINE = /\A(?<lead>(?:>\s*)?(?:\*\*Status:?\*\*:?|Status:)\s*)(?<text>.*)\z/
        HEAD = /\A(?<word>[A-Za-z]+)(?: by \[?(?:ADR )?(?<successor>\d{4})\]?(?:\([^)\s]*\))?)?\.?\s*/
        SETTLES = /Settles finding `(?<finding>[^`]+)`/
        NUMBER = /\A(?<number>\d{4})-/
        TITLE = /\A# (?<title>.+)\z/
        WORD = /[a-z0-9]+/

        # Reads a record's header.
        #
        # @param path [String] a `NNNN-slug.md` file
        # @return [Hash{Symbol => String, nil}] `adr:`, `title:`, `status:` (the leading word,
        #   downcased; nil when the file has no status line), `superseded_by:`, `settles:`, `path:`
        def read(path)
          lines = File.readlines(path, chomp: true)
          status = status_text(lines)
          head = status && HEAD.match(status)
          { adr: File.basename(path)[NUMBER, :number], title: title(lines), path: path,
            status: head && head[:word].downcase, superseded_by: head && head[:successor],
            settles: status && status[SETTLES, :finding] }
        end

        # @param lines [Array<String>] the file's lines
        # @return [String, nil] the text after `# `, nil when the first line is no title
        def title(lines) = lines.first.to_s[TITLE, :title]

        # @param lines [Array<String>] the file's lines
        # @return [String, nil] the status line's text after its label
        def status_text(lines)
          found = lines.first(OPENING).find { |line| STATUS_LINE.match?(line) }
          found && STATUS_LINE.match(found)[:text]
        end

        # Rewrites the title and the status line's leading word, keeping the author's prose after it.
        #
        # @param lines [Array<String>] the file's lines
        # @param title [String] the record's title
        # @param head [String] the new leading words, e.g. `Accepted.`
        # @return [Array<String>] the rewritten lines
        def rewrite(lines, title:, head:)
          lines = lines.dup
          lines[0] = "# #{title}" if title(lines)
          index = lines.first(OPENING).index { |line| STATUS_LINE.match?(line) }
          lines[index] = status_line(lines[index], head) if index
          lines
        end

        # @return [String] the status line with its leading words replaced by `head`
        def status_line(line, head)
          match = STATUS_LINE.match(line)
          rest = match[:text].sub(HEAD, "")
          "#{match[:lead]}#{head}#{" #{rest}" unless rest.empty?}"
        end

        # The lines of a new record: its title, a status line, and the three headings to fill in.
        #
        # @param title [String] the record's title
        # @param head [String] the leading words of its status line
        # @param date [String] the day it was drafted, `YYYY-MM-DD`
        # @param settles [String, nil] the finding it settles
        # @return [Array<String>] the new file's lines
        def skeleton(title:, head:, date:, settles: nil)
          status = "**Status:** #{head} Date: #{date}.#{" Settles finding `#{settles}`." if settles}"
          ["# #{title}", "", status, "", "## Context", "", "## Decision", "", "## Consequences"]
        end

        SLUG_LENGTH = 90

        # @param title [String] a record's title
        # @return [String] the slug a new record's file name takes: its words, joined by dashes, as
        #   many whole words as fit in {SLUG_LENGTH} characters
        def slug(title)
          title.downcase.scan(WORD).reduce("") do |slug, word|
            longer = slug.empty? ? word : "#{slug}-#{word}"
            longer.length > SLUG_LENGTH ? (return slug) : longer
          end
        end
      end
    end
  end
end
