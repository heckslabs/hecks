module Hecks
  module Adapters
    module Driving
      module Resident
        # The name a resident's process shows in the process table (`ps`, Activity Monitor's
        # inspector), so that a person can tell a resident from a line, which command a line runs,
        # and for which checkout. Each title keeps what the readers of the process table look
        # for: a resident's holds `resident/server.rb` and its checkout ({Stuck}), and a line's
        # starts with the launcher's own path, as a cold launcher's command line does.
        module Title
          # What a resident's title holds beside its checkout; {Stuck} looks for it.
          SERVER = "resident/server.rb".freeze
          # A word that can be part of a command's name: a domain, or an aggregate and its verb.
          WORD = /\A[\w:.!?]+\z/
          # How many leading words are looked at for the command.
          WORDS = 3

          module_function

          # @param root [String] the checkout or worktree the resident serves
          # @return [String] `hecks resident <its name> (resident/server.rb <its path>)`
          def resident(root) = "hecks resident #{File.basename(root)} (#{SERVER} #{root})"

          # @param script [String] the launcher the line runs
          # @param argv [Array<String>] the line's words
          # @return [String] the launcher's path and the command, e.g.
          #   `/checkout/exe/hecks tickets Work.undone`, with no argument of the line
          def line(script, argv) = [script, *command(argv)].join(" ")

          # The words that name the command: the leading words up to the first that holds a dot
          # (`Work.undone`). An argument's value never shows, because every user can read the
          # process table: with no dotted word among them only the first word is kept.
          #
          # @param argv [Array<String>] the line's words
          # @return [Array<String>] at most `WORDS` words
          def command(argv)
            words = Array(argv).first(WORDS).take_while { |word| word.to_s.match?(WORD) }
            named = words.index { |word| word.include?(".") }
            named ? words[0..named] : words.first(1)
          end

          # Names this process.
          #
          # @param title [String] what the process table shows for it
          # @return [void]
          def apply(title) = Process.setproctitle(title)
        end
      end
    end
  end
end
