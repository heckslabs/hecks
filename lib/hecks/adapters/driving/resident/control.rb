require "hecks/adapters/driving/resident/paths"

module Hecks
  module Adapters
    module Driving
      module Resident
        # Which lines a launcher in a linked worktree may ask the primary checkout's resident
        # to run, and where that checkout is. A control command acts on the primary's shared
        # stores (work items, messages, settings, the red flag), so the primary's code serving it
        # is correct; a line about the worktree's own files or code is never one.
        #
        # The words are the world's `resident "Launcher", control: ...`, which a resident writes to
        # the cache directory for the launchers, so none of this loads the domain. With no words
        # written the launcher asks only its own checkout. It uses only the standard library.
        module Control
          # The cache file the resident keeps the world's control words in.
          WORDS = "control".freeze
          # The line a linked worktree's `.git` file names its administrative directory on.
          GITDIR = /\Agitdir:\s*(.+)$/
          # The variables that say which gems a process loads: the control process serves its
          # control lines from its own gems, whatever the caller carries.
          GEM_ENV = %w[GEM_HOME GEM_PATH BUNDLE_GEMFILE RUBYOPT RUBYLIB].freeze

          module_function

          # @param argv [Array<String>] the line's words
          # @param words [Array<String>] the control words: an aggregate (`work`) or an
          #   aggregate and verb (`redflag.status`), spelled as {Client.plain} spells a command
          # @return [Boolean] whether the line is a control command
          def line?(argv, words = Paths.recall_words(WORDS))
            argv.first(2).map { |word| plain(word) }.any? do |word|
              words.any? { |named| word == named || word.start_with?("#{named}.") }
            end
          end

          # @return [String] a command word as {Client.plain} spells it
          def plain(word)
            bare = word.to_s.delete_prefix("Hecks::")
            bare.delete("_").downcase.chomp("!")
          end

          # Asks the primary checkout's resident to run a control line a worktree's own resident was
          # not there to run, with the primary's own launcher: it serves a line made by its own
          # launcher only. The primary's code serves the line, and stderr says so.
          #
          # @param client [#ask] the launcher's client
          # @param root [String] the worktree
          # @param own [String, nil] why the worktree's own resident did not serve (nil: none stood)
          # @return [Array(Integer, nil), Array(nil, String)] as `ask`, a refusal named
          #   `via-primary:<reason>`; the worktree's own answer when the line is not one to ask it
          def via_primary(client, root, own)
            primary = line?(ARGV) && primary_root(root)
            return [nil, own] unless primary

            status, why = client.ask(primary, File.join(primary, "exe", "hecks"))
            warn("hecks: served by the primary checkout's resident") if status
            [status, why && "via-primary:#{why}"]
          end

          # Asks the control process, the primary checkout's resident, to run a control line from a
          # linked worktree, before any resident of the worktree's own. With none answering it says so
          # on stderr and the line goes on cold.
          #
          # @param client [#ask] the launcher's client
          # @param root [String] the worktree
          # @return [Array(Integer, nil), Array(nil, String), nil] as `ask`; nil when the line is not
          #   a control line or `root` has no primary
          def direct(client, root)
            primary = line?(ARGV) && primary_root(root)
            return unless primary

            status, why = client.ask(primary, File.join(primary, "exe", "hecks"))
            warn("hecks: control process down, running cold") unless status || why
            warn("hecks: served by the primary checkout's resident") if status
            [status, why && "via-primary:#{why}"]
          end

          # Asks the control process for a control line from a worktree, else the checkout's own
          # resident, and the primary's when a worktree's own had none to ask.
          #
          # @return [Array] whether the control process was asked, then the status and the reason
          def answer(client, root, script)
            direct = direct(client, root)
            status, why = direct || client.ask(root, script)
            status, why = via_primary(client, root, why) unless direct || status || why
            [direct, status, why]
          end

          # Writes the world's control words where the launchers read them.
          #
          # @param world [#for_verb, nil] the Hecks world
          # @return [void]
          def remember(world)
            Paths.remember(WORDS, (world ? world.for_verb("resident")[:control].to_s.split : []).join("\n"))
          end

          # @param root [String] a checkout
          # @return [String, nil] the primary checkout when `root` is a linked worktree of it and
          #   the primary has a launcher; nil for a checkout of its own or an unknown layout
          def primary_root(root)
            common = common_dir(root)
            primary = common && File.dirname(common)
            primary if primary && primary != root && File.file?(File.join(primary, "exe", "hecks"))
          rescue SystemCallError
            nil
          end

          # @return [String, nil] the repository's `.git` directory the worktree's file names
          def common_dir(root)
            file = File.join(root, ".git")
            return unless File.file?(file)

            admin = File.read(file)[GITDIR, 1]
            admin && File.realpath(File.expand_path(File.read(File.join(admin, "commondir")).strip, admin))
          end
        end
      end
    end
  end
end
