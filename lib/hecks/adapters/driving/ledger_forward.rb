# frozen_string_literal: true

require "open3"
require_relative "exit_status"
require_relative "write_guard"

module Hecks
  module Adapters
    module Driving
      # Runs a worktree's write in the main checkout when the worktree would lose it.
      #
      # A linked worktree lacks the gitignored overlay files that bind some aggregates to a shared
      # ledger, so a command that writes one stores in the worktree's Memory and the shared ledger
      # never hears of it. `WriteGuard` finds those commands; this runs the same line with the main
      # checkout's launcher, in the main checkout, and answers what it answered. A command that
      # names a checkout (`checkout.value=`) and was given none is given the worktree, since the
      # main checkout would otherwise read its own directory as the default.
      module LedgerForward
        # The launcher of a checkout, relative to its root.
        LAUNCHER = "exe/hecks"

        # The argument that names the checkout a command works on.
        CHECKOUT = /\Acheckout(\.value)?\z/

        # Runs a launcher in a directory with an environment and answers its output and status.
        RUNNER = lambda do |env, launcher, args, directory|
          Open3.capture3(env, launcher, *args, chdir: directory)
        end

        module_function

        # @param plan [Hash] the resolved line: `:spec`, `:bluebook`, `:asking`
        # @param argv [Array<String>] the line as typed, without the launcher
        # @param err [#puts] where a forwarded run's standard error goes
        # @param seams [Hash] `:directory` (the checkout the line runs in), `:env` (which also
        #   carries the forwarding switches), `:stores` (answers the store rows of a directory)
        #   and `:runner` (runs the main checkout's launcher); each defaults to the real one
        # @return [Array(String, Integer), nil] the text and status the line ended with, or nil
        #   when the line runs here
        def call(plan, argv, err, **seams)
          return if plan[:asking]

          directory = seams.fetch(:directory) { Dir.pwd }
          verdict = verdict_for(plan, directory, seams)
          return [verdict.refusal, ExitStatus::REFUSED] if verdict.refusal
          return unless verdict.forward

          forward(verdict.forward, line_for(plan[:spec], argv, directory), err, seams.fetch(:runner, RUNNER))
        end

        # @return [WriteGuard::Verdict] what the guard decides for the line's aggregate
        def verdict_for(plan, directory, seams)
          stores = seams.fetch(:stores, WriteGuard::STORES)
          env = seams.fetch(:env, ENV)
          WriteGuard.verdict(directory, plan[:bluebook]&.name, aggregate: plan[:spec][:group], stores: stores, env: env)
        end

        # The line as the main checkout runs it: the worktree is named when the command takes a
        # checkout and the caller gave none.
        #
        # @return [Array<String>]
        def line_for(spec, argv, directory)
          return argv unless takes_checkout?(spec) && !names_checkout?(argv)

          root = WorktreeOverlay.checkout_root(directory)
          root ? argv + ["checkout.value=#{root}"] : argv
        end

        # @return [Boolean] whether the caller already named a checkout
        def names_checkout?(argv)
          argv.any? { |word| word.start_with?("checkout=", "checkout.value=") }
        end

        # @return [Boolean] whether the command has an argument naming the checkout
        def takes_checkout?(spec)
          Array(spec[:arguments]).any? { |argument| argument[:path].to_s.match?(CHECKOUT) }
        end

        # Runs the line in the main checkout and relays the result.
        #
        # @return [Array(String, Integer)] the standard output and the exit status; a failed run
        #   with nothing on standard output answers its standard error as the text
        def forward(main, args, err, runner)
          launcher = File.join(main, LAUNCHER)
          return [unreachable(main), ExitStatus::REFUSED] unless File.file?(launcher)

          out, error, status = runner.call(forwarded_env, launcher, args, main)
          code = exit_code(status)
          return [error.to_s, code] if code != ExitStatus::ANSWERED && out.to_s.empty?

          err.print(error) unless error.to_s.empty?
          [out.to_s, code]
        end

        # What a forwarded run adds to the environment: the mark that stops a second forward, and no
        # Gemfile, so the main checkout's launcher picks its own.
        #
        # @return [Hash{String => String, nil}]
        def forwarded_env
          { WriteGuard::FORWARDED => "1", "BUNDLE_GEMFILE" => nil }
        end

        # @return [Integer] the exit status, 128 plus the signal for a run a signal ended
        def exit_code(status)
          status.exitstatus || (128 + status.termsig.to_i)
        end

        # @return [String] why the main checkout could not run the line
        def unreachable(main)
          "hecks: refused: the main checkout (#{main}) has no #{LAUNCHER} to run this write in"
        end
      end
    end
  end
end
