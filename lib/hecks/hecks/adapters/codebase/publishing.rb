# frozen_string_literal: true

require "stringio"
require "hecks/release/runner"
require_relative "tree"
require_relative "gem_registry"
require_relative "secret_vault"
require_relative "release_facts"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `PublishingRun` asks of the working tree once the release is cleared:
      # cutting the release, or pushing the gem alone.
      #
      # A release is `Hecks::Release::Runner`: it tags the release commit, publishes the gem and
      # gets the client package published, skipping what a registry already lists. Its rules were
      # judged before it starts (the givens of `Clear`), so it is handed the facts they cleared and
      # checks only that its tools are installed. Unconfirmed it is the dry run: every check and
      # build, and nothing tagged, pushed or published. The answer says which steps were really
      # carried out, so the journal can advance the root `Release`: tagged, published, verified.
      module Publishing
        # Every operation this family carries out.
        OPERATIONS = %w[publish publish_gem].freeze

        class << self
          # @return [#capture, #run!, nil] starts every process a release runs; the real ones
          #   (`Hecks::Release::Runner::Commands`) when nil. A spec replaces it, so nothing is
          #   tagged, pushed, published or fetched.
          attr_accessor :commands

          # @return [Hash] extra arguments for the release, such as `pause:` and `now:`, so a spec
          #   can wait for the registry without sleeping
          attr_accessor :release_options
        end

        module_function

        # The facts of a tree that is not a checkout: placeholders that satisfy the value objects,
        # so the checkout rule is the one that refuses.
        #
        # @param operation [String] `publish` or `publish_gem`
        # @return [Hash] every fact a release is judged by, none of them true
        def no_facts(operation)
          none = { value: "none" }
          { operation: { value: operation }, version: { value: "0.0.0" }, client_version: { value: "0.0.0" },
            ir_version: { value: "0.0.0" }, ships_from: { path: "none" }, branch: none, head: none, release_lane: none,
            tag_state: none, on_origin: { value: false }, clean: { value: false }, changelog: { value: false },
            approved: { value: false } }
        end

        # Carries out an accepted request.
        #
        # @param operation [String] `publish` or `publish_gem`
        # @param held [Hash] the `PublishingRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused; the release starts its own processes
        # @return [Hash] `report`, `tagged`, `published` and `verified`, and `version` for the
        #   `Release` record
        # @raise [ConsoleCapture::Failure] when the release refuses or a step fails, with its words
        def call(operation, held, tree, shell: nil)
          _ = shell
          args = held.transform_values { |value| value.is_a?(Hash) && value.key?(:value) ? value[:value] : value }
          commands = Publishing.commands || Release::Runner::Commands.new
          if operation == "publish_gem"
            publish_gem(args, tree, commands)
          else
            publish(args, tree, commands)
          end
        end

        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @param commands [#capture, #run!] starts each process
        # @return [Hash] what the release did
        # @raise [ConsoleCapture::Failure] when the release stops before any real step; one that
        #   stops after a real step answers, with `succeeded` false, so the steps are recorded
        def publish(args, tree, commands)
          out = StringIO.new
          err = StringIO.new
          runner = release(args, tree, commands, out, err)
          status = runner.call
          text = transcript(out, err)
          raise ConsoleCapture::Failure, text if !status.zero? && runner.steps.empty?

          outcome(text, args, **steps_taken(runner, status))
        end

        # @return [String] what the release printed to either stream, trimmed
        def transcript(out, err)
          [out, err].map { |stream| stream.string.strip }.reject(&:empty?).join("\n")
        end

        # @return [Hash] which steps the release really carried out, and whether it ended well
        def steps_taken(runner, status)
          { tagged: runner.steps.include?(:tagged), published: runner.steps.include?(:gem),
            verified: runner.verified, succeeded: status.zero? }
        end

        # @return [Hecks::Release::Runner] the release, over the facts the run was cleared by
        def release(args, tree, commands, out, err)
          options = runner_options(args)
          facts = Release::Runner::Preflight::Facts.new(version: args[:version], sha: args[:head])
          Release::Runner.new(root: tree.root, options: options, commands: commands, input: StringIO.new, out: out,
                              err: err, facts: facts, **(Publishing.release_options || {}))
        rescue ArgumentError => e
          raise ConsoleCapture::Failure, e.message
        end

        # @return [Hecks::Release::Runner::Options] the release's switches: a dry run unless
        #   confirmed
        def runner_options(args)
          flag = ->(name) { args[name] == true }
          Release::Runner::Options.new(dry_run: args[:confirm] != true, gem_only: flag.call(:gem_only),
                                       npm_only: flag.call(:npm_only), npm_local: flag.call(:npm_local),
                                       no_wait: flag.call(:no_wait), yes: true)
        end

        # Pushes the gem alone, or builds it and deletes it again when unconfirmed.
        #
        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @param commands [#capture, #run!] starts each process
        # @return [Hash] what was done
        # @raise [ConsoleCapture::Failure] when the build or the push fails, or the vault is missing
        def publish_gem(args, tree, commands)
          registry = GemRegistry.new(root: tree.root, commands: commands)
          version = args[:version]
          return dry_gem(registry, version, args) unless args[:confirm] == true
          raise ConsoleCapture::Failure, "1Password CLI (op) not found; install it: brew install 1password-cli" unless
            SecretVault.new(commands: commands).installed?

          registry.push!(version)
          verified = registry.published?(version)
          outcome("Released hecks #{version}.", args, tagged: false, published: true, verified: verified)
        rescue Release::Runner::CommandFailed, Release::Runner::Refusal => e
          raise ConsoleCapture::Failure, e.message
        end

        # @return [Hash] the answer of a gem push that only built the gem
        def dry_gem(registry, version, args)
          registry.build_only!(version)
          outcome("dry run, built hecks-#{version}.gem and deleted it; nothing was pushed (add --confirm)",
                  args, tagged: false, published: false, verified: false)
        rescue Release::Runner::CommandFailed => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param steps [Hash] `tagged`, `published` and `verified`, and `succeeded` (true when
        #   absent)
        # @return [Hash] the answer the journal records: a report, what was done, and the release
        def outcome(text, args, **steps)
          { report: { value: text }, tagged: { value: steps[:tagged] }, published: { value: steps[:published] },
            verified: { value: steps[:verified] }, succeeded: { value: steps.fetch(:succeeded, true) },
            version: { value: args[:version] }, ir_version: { value: args[:ir_version] },
            ships_from: args[:ships_from] }
        end
      end
    end
  end
end
