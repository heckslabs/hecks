# frozen_string_literal: true

require "tempfile"

module Hecks
  module Tools
    module RegenerationRun
      # Forks one `hecks project_rust` child per domain, up to `workers` at a time, and prints each
      # child's output whole, in domain order, as soon as every domain before it has been printed.
      #
      # A child inherits the parent's memoized grammar registry through the fork. Its output goes to
      # a temporary file, so a child that writes a lot never waits on a reader. A child that fails
      # stops the pool from starting more; the ones already running are left to finish, so no
      # child is cut off in the middle of a write. The run then aborts, naming the failed domains.
      class Pool
        # What a child runs: `hecks project_rust` with the domain and the declared-domain flags,
        # writing to the streams it was given.
        PROJECT_RUST = lambda do |argv|
          Hecks::RustBuild.run("project_rust", argv, out: STDOUT, err: STDERR) # rubocop:disable Style/GlobalStdStream
        end

        # @param domains [Array<String>] the domains, in the order their output is printed
        # @param flags [Array<String>] the declared-domain flags every child is given
        # @param workers [Integer] how many children may run at once
        # @param runner [#call] what a child does with its argument list, answering an exit status
        def initialize(domains, flags, workers, runner: PROJECT_RUST)
          @domains = domains
          @flags = flags
          @workers = workers
          @runner = runner
          @pending = domains.each_index.to_a
          @running = {}
          @results = {}
          @shown = Set.new
          @finished = Queue.new
        end

        # Runs every domain, or until one fails and the children already running are done.
        #
        # @return [void]
        # @raise [SystemExit] when a child fails: the message names every domain that did
        def call
          start_children
          until @running.empty?
            finish(*@finished.pop)
            start_children
          end
          print_rest
          abort_on_failure
        ensure
          stop_children
        end

        private

        def start_children
          while @running.size < @workers && failed.empty? && (index = @pending.shift)
            @running[index] = start(index)
          end
        end

        # @return [Array<Integer>] the indexes of the children that ended badly, in domain order
        def failed = @results.reject { |_, (_, status)| status.success? }.keys.sort

        # @return [Array(Integer, Tempfile)] the child's process id and its output file
        def start(index)
          out = Tempfile.new("regen-project-rust")
          pid = fork { run_child(out, [@domains[index], *@flags]) }
          Thread.new { @finished << [index, Process.wait2(pid).last] }
          [pid, out]
        end

        def finish(index, status)
          _, out = @running.delete(index)
          @results[index] = [out, status]
          print_ready
        end

        # Prints the finished children in domain order, each once every domain before it is shown.
        def print_ready
          next_up = (0...@domains.size).find { |index| !@shown.include?(index) }
          while next_up && @results.key?(next_up)
            show(next_up)
            next_up += 1
          end
        end

        # After a failure some domains were never started: shows the ones that ran, in order.
        def print_rest
          @results.keys.sort.each { |index| show(index) unless @shown.include?(index) }
        end

        def show(index)
          @shown << index
          out, = @results.fetch(index)
          puts "== hecks project_rust #{@domains[index]} =="
          out.rewind
          $stdout.write(out.read)
          out.close!
          puts
        end

        def abort_on_failure
          names = failed
          return if names.empty?

          first, *others = names
          also = others.empty? ? "" : " (also failed: #{others.map { |index| @domains[index] }.join(", ")})"
          abort "hecks regenerate_corpus: hecks project_rust #{@domains[first]} failed " \
                "(#{@results.fetch(first).last.inspect})#{also}"
        end

        # Ends the children still running when the parent leaves early (an interrupt, say).
        def stop_children
          @running.each_value do |pid, _|
            Process.kill("TERM", pid)
          rescue Errno::ESRCH
            next
          end
        end

        # @param out [Tempfile] the child's end, which becomes its stdout and stderr
        # @param argv [Array<String>] the arguments of `hecks project_rust`
        # @return [void] never returns: the child leaves without the parent's exit handlers
        def run_child(out, argv)
          # The real descriptors, not the globals: a caller may have swapped those for a buffer.
          STDOUT.reopen(out) # rubocop:disable Style/GlobalStdStream
          STDERR.reopen(out) # rubocop:disable Style/GlobalStdStream
          $stdout = STDOUT
          $stderr = STDERR
          status = child_status(argv)
          $stdout.flush
          exit!(status)
        end

        # @return [Integer] the exit status of the runner with the arguments
        def child_status(argv)
          @runner.call(argv)
        rescue SystemExit => e
          e.status
        rescue StandardError => e
          warn "#{e.class}: #{e.message}"
          1
        end
      end
    end
  end
end
