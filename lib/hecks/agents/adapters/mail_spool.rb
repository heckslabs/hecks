# frozen_string_literal: true

require "json"
require "hecks/catcher/adapters/spool_cursor"

module Hecks
  module Adapters
    # The `MailSpooling` port's adapter for `MailSpool`: answers `Read` with the first complete
    # line past the cursor and `Acknowledge` by moving the cursor, in the spool file a send appends
    # to (`.claude/hooks/mail_send.sh`).
    #
    # It never writes a line to the spool, and decides nothing about what a line means: the
    # bluebook sends each one as a message. A line it cannot parse is skipped over, not answered.
    class MailSpool
      # Where a send appends, under the dev directory, when the settings name no other path.
      DEFAULT_PATH = "~/.claude/hecks-dev/mail/spool.jsonl"

      # The fields a spool line carries, each answered as `{ value: }`.
      FIELDS = %w[message recipient sender kind body in_reply_to asker_role advance open to].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the spool file (default {DEFAULT_PATH})
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @cursor = SpoolCursor.new({ path: DEFAULT_PATH }.merge(settings))
      end

      # @param pass [Hash] the pass asking, passed back
      # @return [Hash{Symbol => Hash}] the line as `{ value: }` fields with `line:` its number, or
      #   an empty `message:` when no complete line is left past the cursor
      # @raise [SystemCallError] when the spool or the cursor exists and cannot be read
      def read(pass:, **)
        done = @cursor.position
        lines.each_with_index.drop(done).each do |text, index|
          fields = parsed(text)
          return answer(pass, fields, index + 1) if fields
        end
        FIELDS.to_h { |key| [key.to_sym, { value: "" }] }.merge(pass: pass)
      end

      # @param pass [Hash] the pass asking
      # @param line [Hash] the line number kept, `{ value: }`
      # @return [Hash{Symbol => Hash}] `pass:` and `next_pass:`, the key of the pass that follows
      # @raise [SystemCallError] when the cursor cannot be written
      def acknowledge(pass:, line:, **)
        count = line[:value]
        @cursor.advance(count)
        { pass: pass, next_pass: { value: "line-#{count}" } }
      end

      private

      def lines
        return [] unless File.file?(@cursor.spool)

        File.foreach(@cursor.spool).select { |text| text.end_with?("\n") }
      end

      def parsed(text)
        fields = JSON.parse(text)
        fields = marked(fields) if fields.is_a?(Hash) && fields["message"].to_s == ""
        fields if fields.is_a?(Hash) && fields["message"].to_s != ""
      rescue JSON::ParserError
        nil
      end

      # A mark line (`mail_mark.sh`) names a seat and a position, and is kept under a message key of
      # its own so the pass takes it like any line.
      def marked(fields)
        seat = fields.values_at("advance", "open").find { |name| name.to_s != "" }
        fields.merge("message" => "mark-#{seat}-#{fields["to"]}") if seat && fields["to"]
      end

      def answer(pass, fields, number)
        FIELDS.to_h { |key| [key.to_sym, { value: fields[key].to_s }] }
              .merge(pass: pass, line: { value: number }, to: { value: fields["to"].to_i })
      end
    end
  end
end
