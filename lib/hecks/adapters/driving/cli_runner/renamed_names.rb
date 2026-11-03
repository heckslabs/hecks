module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher's renamed table at run time: a line that spells a renamed command's old name
        # is noted once on standard error, and its argument names translate before the command reads
        # them. Extended into `CliRunner`.
        module RenamedNames
          # Notes a renamed spelling once, and returns the line's argv with its arguments
          # translated.
          #
          # @param cli [Hash] the projection, holding `:names` with its `:renamed` table
          # @param typed [String] the word typed, without its `!`
          # @param name [String] the name the index resolved the word to
          # @param argv [Array<String>] the line's words, the command name first
          # @return [Array<String>] the words with renamed arguments translated
          def renamed_line(cli, typed, name, argv)
            table = cli.dig(:names, :renamed) || {}
            note_renamed(cli, typed, name) if Array(table[:spellings]).include?(typed)
            translate_arguments(table.dig(:arguments, typed), argv)
          end

          # Says once per process, on standard error, that a line used a renamed command's old name.
          def note_renamed(cli, typed, name)
            target = cli.dig(:names, :command, typed) || cli.dig(:names, :question, typed) || name
            return unless VerbNames::NOTED.add?("spelling #{typed}")

            warn "hecks: #{typed} is the former name of #{target}; use that spelling (this notice prints once)"
          end

          # Rewrites the argument names a renamed table translates (`old=value` to `new=value`); the
          # name word and any other word pass through unchanged.
          def translate_arguments(renames, argv)
            return argv if renames.nil? || renames.empty?

            [argv.first, *argv.drop(1).map { |word| translate_word(renames, word) }]
          end

          # One `old=value` word with its argument renamed when the table names it.
          def translate_word(renames, word)
            key, value = word.split("=", 2)
            return word if value.nil? || !renames.key?(key)

            "#{renames[key]}=#{value}"
          end
        end
      end
    end
  end
end
