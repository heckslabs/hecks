# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../shell"
require_relative "culprit"

module Hecks
  module Adapters
    class GitShallowCheck
      # Runs CI's failing checks in a fresh `--depth 1` clone of a branch tip, the way CI sees it:
      # no history, no git identity, `CI` set.
      #
      # It names the specs that failed and the first failure's message, and removes the clone.
      class CloneRun
        # A red run: the spec files that failed (none for a clone or a fuzz that failed) and what
        # to say about it.
        #
        # @!attribute [r] specs
        #   @return [Array<String>] the failed spec files, relative to the clone
        # @!attribute [r] text
        #   @return [String] the specs and the first failure's message
        Red = Struct.new(:specs, :text)

        # The specs that went red in CI on a checkout that was green: shallow history, load
        # hygiene, shard order, git identity.
        SPECS = %w[
          context_map_hecks reference_doctest mcp_argument_policy glossary reference_golden cli_help_snapshot
          hecks_model_check dsl_coverage word_coverage load_hygiene hecks_tickets_bluebook bounded_context
        ].map { |name| "spec/#{name}_spec.rb" }.freeze

        # The environment of a CI runner: no global or system git configuration, so no identity.
        ENVIRONMENT = { "CI" => "true", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
                        "GIT_AUTHOR_NAME" => nil, "GIT_AUTHOR_EMAIL" => nil, "GIT_COMMITTER_NAME" => nil,
                        "GIT_COMMITTER_EMAIL" => nil }.freeze

        # The program that runs the specs in the clone.
        COMMAND = %w[bundle exec rspec --no-color].freeze

        # @param source [String] the repository to clone
        # @param branch [String] the branch whose tip is cloned
        # @param specs [Array<String>] the spec files to run, relative to the clone
        # @param command [Array<String>] the program that runs them
        # @param shell [Shell] runs every program
        def initialize(source, branch, specs: SPECS, command: COMMAND, shell: Shell.new)
          @source = source
          @branch = branch
          @specs = specs
          @command = command
          @shell = shell
        end

        # @param fuzz [Proc, nil] given the clone's path, answers the domains to fuzz there
        # @return [Red, nil] the failed specs and the first failure's message; nil when green
        def call(fuzz: nil)
          Dir.mktmpdir("hecks-shallow") do |dir|
            clone = File.join(dir, "clone")
            return Red.new([], "clone failed: #{@branch} could not be cloned at depth 1") unless cloned?(clone)

            specs(clone) || fuzzing(clone, fuzz&.call(clone) || [])
          end
        end

        private

        def cloned?(clone)
          @shell.capture("git", "clone", "--quiet", "--depth", "1", "--no-local", "--branch", @branch,
                         "file://#{@source}", clone, env: ENVIRONMENT).ok?
        end

        def specs(clone)
          done = run(clone, *@command, *@specs)
          return if done.ok?

          culprit = Culprit.new(said(done))
          Red.new(culprit.specs, "#{culprit} failed in a depth-1 clone of #{@branch}")
        end

        def fuzzing(clone, domains)
          domains.each do |domain|
            done = run(clone, "bundle", "exec", "exe/hecks", "fuzz_run.fuzz!", "domain.value=#{domain}", "--wait")
            return fuzz_red(domain, done) unless done.ok?
          end
          nil
        end

        def fuzz_red(domain, done)
          Red.new([], "fuzz of #{File.basename(domain)} failed in a depth-1 clone: #{Culprit.new(said(done)).reason}")
        end

        def run(clone, *command)
          @shell.capture(*command, env: ENVIRONMENT.merge(bundle(clone)), chdir: clone)
        end

        # A clone with a Gemfile bundles itself; one without leaves the caller's bundle alone.
        def bundle(clone)
          gemfile = File.join(clone, "Gemfile")
          File.exist?(gemfile) ? { "BUNDLE_GEMFILE" => gemfile } : {}
        end

        def said(done) = done.out + done.err
      end
    end
  end
end
