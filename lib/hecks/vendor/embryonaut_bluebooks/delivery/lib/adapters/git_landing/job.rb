# frozen_string_literal: true

require "rbconfig"
require "fileutils"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class GitLanding
      # A landing that runs without its caller: one detached process that runs `Landing.carry!`
      # through the primary checkout's launcher, so the caller answers in seconds.
      #
      # The process stands in the primary checkout, whose world holds the Work items, so the
      # events the landing emits (`BranchLanded`, `LandingRefused`) and the policies that react to
      # them are recorded where a landing run by hand records them. It measures and dispatches:
      # which refusal sends the Work item back to a coder is the bluebook's.
      class Job
        # How many times the job runs the landing before it gives up on a cause that passes.
        TRIES = 6

        # The seconds the job waits before it runs a landing again; each wait is twice the last.
        PAUSE = 5

        # The longest the job waits between two tries, in seconds.
        LONGEST_PAUSE = 60

        # What a refused landing's output says when the cause passes by itself: `origin/main` moved
        # after the branch was rebased, another process holds the store, or git holds a ref or the
        # index for another landing. The next try pulls `main` and rebases again.
        TRANSIENT = ["that origin/main has", "database is locked", "cannot lock ref", "index.lock"].freeze

        # The characters of a branch name that are replaced when the name is a log file.
        UNSAFE_IN_FILENAME = /[^\w.-]/

        # What the child runs. The log path is the last argument; before it come the launcher, the
        # directory of the bluebook that holds the red flag, the tries, the first pause, then the
        # landing's own arguments. A landing refused because the queue is busy is run again at once,
        # since the next run waits in the line; one refused because main is red is run again once
        # the flag's next event is heard; one refused for a `TRANSIENT` cause is run again after a
        # pause that doubles. The log says so when the tries run out. Every other refusal ends the
        # job: the bluebook has reacted to it.
        # Each statement is one line: the lines are joined with `;` to pass the script to `ruby -e`.
        SCRIPT = <<~RUBY.tr("\n", ";").freeze
          log = ARGV.pop
          launcher, flag, tries, pause, *carry = ARGV
          transient = #{TRANSIENT.inspect}
          note = ->(line) { File.open(log, "a") { |f| f.puts("\#{Time.now.utc.strftime("%FT%TZ")} \#{line}") } }
          listen = [launcher, "Operation.follow", "domain.value=\#{flag}", "aggregate.value=RedFlag", "from_now=true", "wait=600"]
          note.call("landing job begun (pid \#{Process.pid}): \#{carry.join(" ")}")
          tries.to_i.times do |count|
            out = IO.popen([launcher, *carry, { err: [:child, :out] }], &:read)
            note.call("try \#{count + 1}: exit \#{$?.exitstatus.inspect}")
            note.call(out)
            break if $?.success?
            red = out.include?("main is red:")
            cause = transient.find { |text| out.include?(text) }
            break unless red || cause || out.include?("queue busy:")
            break note.call("gave up after \#{tries} tries: \#{cause || "the queue is busy or main is red"}") if count + 1 == tries.to_i
            system(*listen, out: File::NULL, err: File::NULL) if red
            next if red || !cause
            wait = [pause.to_f * (2**count), #{LONGEST_PAUSE}].min
            note.call("\#{cause}: next try in \#{wait.round}s")
            sleep(wait)
          end
          note.call("landing job ended")
        RUBY

        # @param primary [String] the primary checkout, whose launcher and world the job uses
        # @param spawner [#call, nil] starts the child from its argument list and the directory
        #   it stands in (a stand-in in specs); a detached process when nil
        # @param logs [String, nil] the directory the job's log goes to; the git directory's
        #   `hecks-landings` when nil
        # @param pause [Numeric] seconds before the second try of a landing refused for a cause
        #   that passes
        def initialize(primary, spawner: nil, logs: nil, pause: PAUSE)
          @primary = primary
          @pause = pause
          @spawner = spawner || method(:detach)
          @logs = logs || File.join(primary, ".git", "hecks-landings")
        end

        # Starts the job and returns without waiting for it.
        #
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String] a sentence naming the job's log
        # @raise [ConsoleCapture::Failure] when the primary checkout has no launcher
        def start(checkout:, branch:, onto:)
          log = logfile(branch)
          carry = ["Landing.carry!", "checkout.value=#{checkout}", "branch.value=#{branch}", "onto.value=#{onto}",
                   "--confirm", "--wait"]
          @spawner.call([RbConfig.ruby, "-e", SCRIPT, launcher!, flag_domain, TRIES.to_s, @pause.to_s, *carry, log], @primary)
          "handed #{branch} to a landing job; it reports by event (BranchLanded or LandingRefused) and logs to #{log}"
        end

        private

        def launcher!
          launcher = File.join(@primary, "exe", "hecks")
          return launcher if File.executable?(launcher)

          raise ConsoleCapture::Failure, "no launcher at #{launcher} to run the landing job through"
        end

        def flag_domain = File.join(@primary, "lib", "hecks", "hecks")

        def logfile(branch)
          FileUtils.mkdir_p(@logs)
          File.join(@logs, "#{branch.gsub(UNSAFE_IN_FILENAME, "_")}.log")
        end

        def detach(argv, dir)
          Process.detach(Process.spawn(*argv, chdir: dir, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true))
        end
      end
    end
  end
end
