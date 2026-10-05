# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../adapters/git_pr"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control patch.open`: opens a PR and records it in the
    # QualityControl ledger in one step. It is the only door into `QualityControl::Patch.Open` and
    # `QualityControl::Improvement.Open`.
    #
    # It refuses (exit 1, nothing opened or recorded) unless the ledger's own `Open` command would
    # take the record and the `GitPr` adapter agrees. The command's `given`s are the rules, asked
    # as a dry run before anything is opened: the branch starts with the practice's prefix; with
    # `--bug`, the bug is `fixed`; with `--angle`, it is `investigating`. The adapter answers the
    # rest: the tree is clean and the bug's commit is an ancestor of `HEAD`. The per-day cap
    # (`PR_CAP_PER_DAY`, 0 = uncapped) is `DailyQuota.Take`'s own `given`: asked as a dry run with
    # the others, and taken for real once the PR is recorded. It is idempotent. `QA_REPO_DIR`
    # picks the checkout `git` runs in, so a spec can use a throwaway repo and a fake `gh`.
    class QaOpenPr
      EXIT_OK = 0

      USAGE = "usage: hecks quality_control patch.open --bug BUG#n --title \"…\" [--body \"…\"]\n       " \
              "hecks quality_control improvement.open --improvement [--angle ANGLE-n] --title \"…\" [--body \"…\"]"

      SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

      # Stands in for the commit of a bug that is not fixed yet, so its dry run reaches the `given`.
      PLACEHOLDER_COMMIT = "0000000"

      # Opens and records the PR.
      #
      # @param argv [Array<String>] `--bug`, `--improvement`, `--angle`, `--title` and `--body`
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` and `QA_REPO_DIR`
      # @return [Integer] 0 once opened and recorded
      # @raise [SystemExit] with `refused: ...` when a rule refuses, or the arguments are wrong
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` and `QA_REPO_DIR`
      def initialize(root:, env: ENV)
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
        @repo_dir = env.fetch("QA_REPO_DIR", root)
      end

      # @param argv [Array<String>] the command line's arguments
      # @return [Integer] the exit status
      # @raise [SystemExit] with `refused: ...` when a rule refuses, or the arguments are wrong
      def call(argv)
        options = parse(argv.dup)
        return EXIT_OK if options == :help

        @options = options
        @git_pr = Hecks::Adapters::GitPr.new(repo_dir: @repo_dir)
        @branch = refusing { @git_pr.branch }
        refusing { @git_pr.assert_clean_tree! }
        @runtime = boot_ledger
        find_citations
        check_rules
        view = open_pull_request
        record(view)
        merge_when_green(view[:number]) if dial(:AUTO_MERGE, false)
        puts "#{view[:url]} (#{view[:headRefName]} @ #{view[:headRefOid].to_s[0, 7]}) — #{view[:title]}"
        EXIT_OK
      end

      private

      def parse(argv)
        options = {}
        until argv.empty?
          arg = argv.shift
          case arg
          when "-h", "--help"
            puts USAGE
            return :help
          when "--improvement"
            options[:improvement] = true
          when "--bug", "--angle", "--title", "--body"
            value = argv.shift
            abort "#{USAGE}\n#{arg} needs a value" if value.nil? || value.empty?
            options[arg.delete_prefix("--").to_sym] = value
          else
            abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
          end
        end
        validate(options)
      end

      def validate(options)
        abort "#{USAGE}\n--title is required" unless options[:title]
        abort "#{USAGE}\ngive --bug BUG#n OR --improvement, not both" if options[:bug] && options[:improvement]
        abort "#{USAGE}\ngive --bug BUG#n or --improvement" unless options.key?(:bug) || options.key?(:improvement)
        abort "#{USAGE}\n--angle only means something with --improvement" if options[:angle] && !options[:improvement]

        options
      end

      # Every rule the adapter enforces refuses the same way: exit 1, nothing opened or recorded.
      def refusing
        yield
      rescue Hecks::Adapters::GitPr::Refusal, Hecks::Adapters::GitPr::CommandFailed => e
        abort "refused: #{e.message}"
      end

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before opening a PR against it " \
              "(#{e.class}: #{e.message})"
      end

      def query(name, **args) = @runtime.query("QualityControl::#{name}", **args)

      # Falls back to a dial-less fixture ledger's values: uncapped, non-draft, no auto-merge.
      def dial(name, fallback)
        return fallback unless defined?(::QualityControlDials) && ::QualityControlDials.const_defined?(name)

        ::QualityControlDials.const_get(name)
      end

      def find_citations
        @bug = @angle = nil
        if @options[:bug]
          @bug = ::QualityControl::Bug.find(@options[:bug])
          abort "refused: no such bug #{@options[:bug].inspect}" unless @bug
        end
        return unless @options[:angle]

        @angle = ::QualityControl::Angle.find(@options[:angle])
        abort "refused: no such angle #{@options[:angle].inspect}" unless @angle
      end

      # What a refused `given` says to do next, by the rule's own wording; nothing for a rule it
      # does not know.
      def hint_for(rule)
        case rule
        when "the bug is fixed"
          " (#{@bug.id} is #{@bug.status.inspect} — dispatch investigate and fix first " \
          "(hecks run qa/bluebook fix id=#{@bug.id} reference.value=#{@bug.id} commit.value=<sha>))"
        when "the angle is under investigation"
          " (#{@angle.id} is #{@angle.status.inspect} — dispatch angle.investigate first, so the lead " \
          "reads as picked up before something is built from it)"
        when "the branch is one this practice recognises as its own"
          " (the branch is #{@branch.inspect}; a PR this practice opens is on a branch it can recognise " \
          "as its own)"
        when "the day's cap is not spent"
          " (QualityControlDials::PR_CAP_PER_DAY is #{dial(:PR_CAP_PER_DAY, 0)} — leave this as an open " \
          "Bug/Angle and open it tomorrow, or raise the dial in qa/settings.yml)"
        else ""
        end
      end

      # Asks the ledger whether `verb` would take these facts, without recording anything. The
      # number is one no record holds yet, so the dry run reaches the `given`s rather than
      # `AlreadyExists`.
      def refuse_unless_ledger_takes(verb, **facts)
        @runtime.dry_run?(verb, **facts)
      rescue Hecks::Runtime::GivenNotMet => e
        hint = hint_for(e.message.split(" — ", 2).last)
        abort "refused: #{e.message}#{hint} — a dry run of #{verb}, so nothing was opened or recorded"
      end

      def next_number(aggregate)
        query("#{aggregate}.All").map { |row| row[:number][:value] }.max.to_i + 1
      end

      def check_rules
        recorded = { url: { value: "https://github.com/pull/0" }, title: { value: @options[:title] },
                     branch: { value: @branch }, now: { value: Time.now.to_i } }
        if @bug
          commit = @bug.commit.to_h[:value].to_s
          refuse_unless_ledger_takes("QualityControl::Patch.Open",
                                     bug: @bug.id, number: { value: next_number("Patch") },
                                     commit: { value: commit.match?(SHA_PATTERN) ? commit : PLACEHOLDER_COMMIT },
                                     **recorded)
        else
          refuse_unless_ledger_takes("QualityControl::Improvement.Open",
                                     **(@angle ? { angle: @angle.id } : {}),
                                     number: { value: next_number("Improvement") }, **recorded)
        end
        check_daily_cap
        check_ancestry
      end

      # The record of the UTC day the clock reads: `DailyQuota.Today` fills the day from the clock.
      def todays_quota = query("DailyQuota.Today").first

      # A day with no record has spent nothing, so only an opened day can refuse.
      def check_daily_cap
        cap = dial(:PR_CAP_PER_DAY, 0)
        quota = todays_quota
        return unless cap.positive? && quota

        refuse_unless_ledger_takes("QualityControl::DailyQuota.Take", today: quota[:today], cap: { value: cap })
      end

      # Counts the PR just recorded against the day, opening the day's record on its first.
      def take_daily_slot
        row = todays_quota
        quota = row ? ::QualityControl::DailyQuota.find(row[:today][:value]) : ::QualityControl::DailyQuota.open!
        quota.take!(cap: { value: dial(:PR_CAP_PER_DAY, 0) })
      end

      def check_ancestry
        return unless @bug

        commit = @bug.commit.to_h[:value].to_s
        abort "refused: #{@bug.id} carries no commit" unless commit.match?(SHA_PATTERN)

        refusing do
          @git_pr.assert_ancestor!(commit: commit, owner: @bug.id)
          @git_pr.assert_pushed!(branch: @branch, commit: commit, owner: @bug.id)
        end
      end

      # @return [Hash] `gh`'s view of the PR, opened here when the branch had none
      def open_pull_request
        view = refusing { @git_pr.open_pull_request(@branch) }
        if view
          puts "PR ##{view[:number]} already open for #{@branch} — not re-creating"
        else
          create_pull_request
          view = refusing { @git_pr.open_pull_request(@branch) }
          abort "gh pr create returned, but gh pr view #{@branch} shows no open PR — record nothing" unless view
        end
        sha = view[:headRefOid].to_s
        unless sha.match?(SHA_PATTERN)
          abort "refused: gh reports head #{sha.inspect} for ##{view[:number]}, which does not look like a sha"
        end

        check_pr_head(sha)
        view
      end

      # The PR must carry the fix commit, whether this run opened it or an earlier one did.
      def check_pr_head(sha)
        return unless @bug

        refusing { @git_pr.assert_pr_head!(head: sha, commit: @bug.commit.to_h[:value].to_s, owner: @bug.id) }
      end

      def create_pull_request
        # The body names the ledger record so the PR and the ledger point at each other.
        cited = if @bug then "Fixes #{@bug.id}."
                elsif @angle then "Builds #{@angle.id}."
                else "Deliberate work, no Bug or Angle behind it."
                end
        body = @options[:body] ||
               "#{cited}\n\nOpened by hecks quality_control patch.open and recorded in the QualityControl ledger."
        begin
          @git_pr.create_pull_request(branch: @branch, title: @options[:title], body: body,
                                      draft: dial(:DRAFT_ONLY, false))
        rescue Hecks::Adapters::GitPr::CommandFailed => e
          abort e.message
        end
      end

      def record(view)
        number = view[:number]
        sha = view[:headRefOid].to_s
        now = Time.now.to_i
        if @bug
          record_patch(view, number, sha, now)
        else
          record_improvement(view, number, sha, now)
        end
      end

      def record_patch(view, number, sha, now)
        if query("Patch.All").map { |row| row[:number][:value] }.include?(number)
          puts "Patch ##{number} already recorded — not re-recording"
          return
        end

        ::QualityControl::Patch.open!(
          bug: @bug.id, number: { value: number }, url: { value: view[:url] },
          branch: { value: view[:headRefName] }, commit: { value: sha }, title: { value: view[:title] },
          now: { value: now }
        )
        take_daily_slot
        puts "recorded Patch ##{number} for #{@bug.id} at #{sha[0, 7]}"
      end

      def record_improvement(view, number, sha, now)
        existing = ::QualityControl::Improvement.find(number)
        if existing && existing.status != "opened"
          puts "Improvement ##{number} already recorded (#{existing.status}) — not re-recording"
          return
        end

        # A run that stopped between `open!` and `land!` leaves the record `opened`: finish it.
        unless existing
          ::QualityControl::Improvement.open!(
            **(@angle ? { angle: @angle.id } : {}),
            number: { value: number }, url: { value: view[:url] },
            branch: { value: view[:headRefName] }, title: { value: view[:title] },
            now: { value: now }
          )
          take_daily_slot
        end
        ::QualityControl::Improvement.find(number).land!(number: { value: number }, commit: { value: sha })
        puts "recorded Improvement ##{number}#{" for #{@angle.id}" if @angle}, landed at #{sha[0, 7]}"
      end

      def merge_when_green(number)
        begin
          @git_pr.merge_when_green(number)
        rescue Hecks::Adapters::GitPr::CommandFailed => e
          abort "recorded, but #{e.message}"
        end
        puts "auto-merge queued for ##{number} (QualityControlDials::AUTO_MERGE)"
      end
    end
  end
end
