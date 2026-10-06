# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    # The regular expressions the comment linters match comment text against.
    module CommentStyle
      # Multi-word SQL is protected as a phrase, because the individual keywords
      # (`FROM`, `WHERE`, `TABLE`) are also ordinary English emphasis targets.
      SQL_PHRASES = Regexp.union(
        /\bINSERT INTO\b/, /\bSELECT\b.*?\bFROM\b/, /\bORDER BY\b/, /\bGROUP BY\b/,
        /\bON CONFLICT\b(?: DO (?:NOTHING|UPDATE))?/, /\bDO NOTHING\b/, /\bFOR (?:UPDATE|SHARE)\b/,
        /\bSKIP LOCKED\b/, /\b(?:PRIMARY|FOREIGN) KEY\b/, /\bIS(?: NOT)? NULL\b/, /\bNOT NULL\b/,
        /\bCREATE (?:UNIQUE )?(?:TABLE|INDEX|POLICY|ROLE|SCHEMA|TRIGGER|FUNCTION)\b/,
        /\bALTER (?:TABLE|ROLE|SCHEMA)\b/, /\bDROP (?:TABLE|COLUMN|INDEX|SCHEMA|POLICY)\b/,
        /\bADD (?:COLUMN|CONSTRAINT)\b/, /\bDELETE FROM\b/, /\bUNION ALL\b/, /\bSET LOCAL\b/,
        /\bBEGIN (?:IMMEDIATE|EXCLUSIVE|DEFERRED)\b/, /\bROW LEVEL SECURITY\b/,
        /\bCREATE \.\.\. PARTITION OF\b/, /\bPARTITION OF\b/, /\bIF (?:NOT )?EXISTS\b/,
        /\b(?:LEFT|INNER|OUTER|CROSS) JOIN\b/, /\bLIMIT \d+\b/, /\bOWNER TO\b/, /\b(?:on|in|onto) PATH\b/
      ).freeze

      PROTECTED_SPANS = Regexp.union(
        /`[^`]*`/, /"[^"]*"/, /'[^'\s]*'/, %r{\b[a-z]+://\S+}, SQL_PHRASES,
        /\b(?:NOTE|OPTIMIZE|HACK|REVIEW):/
      ).freeze

      CAPS_WORD = /
        (?<![\w:.\#@$'])
        (?:A|[A-Z]{2,}(?:'[A-Z]{1,2})?)
        (?![\w(]|'(?!s\b|\s|$)|-[a-z](?<=POST-.)|::|\.\w|\#\d|\s*=(?![=~>])|\s*←)
      /x

      HISTORY = [
        /\bused to\b/i, /\bwas originally\b/i, /\boriginally (?:was|were|used|lived|named|called)\b/i,
        /\bpreviously\b/i, /\bformerly\b/i, /\bhistorically\b/i, /\bstale as of\b/i,
        /\b(?:was|were|been|got) renamed\b/i, /\brenamed from\b/i, /\bhas since\b/i,
        /\bbefore (?:this|the) (?:change|fix|refactor|split|rename|pr|commit|patch)\b/i, /\bBefore this, /,
        /\ban? earlier (?:version|revision|draft|pass)\b/i, /\bwhen this was (?:written|added)\b/i,
        /\b(?:in|since|by|after|before|until) (?:PR )?\#\d{2,}/i, /\bPR \#?\d{2,}\b/,
        /\bno longer\b/i, /\bany more\b/i, /\banymore\b/i
      ].freeze

      DIRECTIVE = /\A#\s*(?:rubocop:|frozen_string_literal:|encoding:|coding:|shareable_constant|typed:|!)/

      # Stands in for a protected span so it still reads as a word, not a gap.
      FILLER = "§"

      # What may sit between the words of one all-caps heading run.
      GAP = %r{\A(?:[\s,/&'\-\d]|#{FILLER}|[A-Z]{2,})*\z}

      # A bold phrase opening a comment line, after an optional bullet.
      BOLD_HEADING = /\A(#+\s*(?:[-*]\s+)?)\*\*([^*]+)\*\*/

      # What ends a heading run: an em dash, or sentence punctuation.
      HEADING_END = /\A(?:\s+—|[.:!?](?:\s|\z))/

      CODE_NOISE = %i[on_comment on_sp on_nl on_ignored_nl].freeze
    end
  end
end
