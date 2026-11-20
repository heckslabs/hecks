require "fileutils"
require "json"
require "tmpdir"

# A scratch project and a stand-in `aws` program for the `BoxState` query: a temporary directory
# holding a `deploy-box.sh` that assigns the stack names, and an `aws` that answers each read from
# a file of that directory and appends the call to `calls.log`. Nothing reaches AWS.
module BoxStateStandIn
  AWS = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "$1 $2" >> "$STUB_DIR/calls.log"
    args="$*"
    case "$1 $2" in
      "cloudformation describe-stacks")
        case "$args" in
          *InstanceId*) cat "$STUB_DIR/instance" ;;
          *DbEndpoint*) echo widget-db.abc.us-east-1.rds.amazonaws.com ;;
        esac ;;
      "ssm list-commands") case "$args" in *value=InProgress*) cat "$STUB_DIR/in_progress" ;; esac ;;
      "ssm send-command") printf '%s' "$args" > "$STUB_DIR/sent"; echo cmd-1 ;;
      "ssm get-command-invocation")
        case "$args" in
          *StandardOutputContent*) cat "$STUB_DIR/containers" ;;
          *) cat "$STUB_DIR/command_status" ;;
        esac ;;
      "rds describe-db-instances") [ -f "$STUB_DIR/backups" ] || exit 254; cat "$STUB_DIR/backups" ;;
      *) echo "unexpected aws $1 $2" >&2; exit 1 ;;
    esac
  BASH

  SCRIPT = <<~BASH.freeze
    #!/bin/bash
    BOX_STACK=widget-box
    RDS_STACK=widget-rds
    REGION=us-east-1
    DIR=/opt/widget
  BASH

  # Every `aws` call one read of a settled box makes, in order, each named once.
  READS = ["cloudformation describe-stacks", "ssm list-commands", "ssm send-command",
           "ssm get-command-invocation", "rds describe-db-instances"].freeze

  REVISION = "4f1c2d3e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d".freeze
  REGISTRY = "123456789012.dkr.ecr.us-east-1.amazonaws.com".freeze

  # A scratch box: what each stand-in read answers, as files a spec rewrites.
  class Box
    attr_reader :dir

    # @param dir [String] the scratch directory
    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p([File.join(dir, "bin"), project])
      File.write(File.join(dir, "bin", "aws"), AWS, perm: 0o755)
      File.write(File.join(project, "deploy-box.sh"), SCRIPT)
      settle
    end

    # @return [String] the project directory that holds `deploy-box.sh`
    def project = File.join(dir, "project")

    # Sets one answer.
    #
    # @param name [Symbol] `instance`, `in_progress`, `containers`, `command_status` or `backups`
    # @param text [String, nil] what the read answers; nil removes the answer
    # @return [void]
    def answer(name, text)
      path = File.join(dir, name.to_s)
      text.nil? ? FileUtils.rm_f(path) : File.write(path, text)
    end

    # @return [Array<String>] each `aws` call made, as its service and verb
    def calls = File.exist?(log) ? File.readlines(log, chomp: true) : []

    # @return [String] the arguments of the command sent to the box
    def sent = File.read(File.join(dir, "sent"))

    # The variables that put the stand-in first on `PATH`.
    #
    # @return [Hash{String => String}]
    def env = { "PATH" => "#{File.join(dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => dir, "SSM_POLL_SECS" => "0" }

    private

    def log = File.join(dir, "calls.log")

    # A settled box: two containers of one revision, no command running, backups kept seven days.
    def settle
      answer(:instance, "i-0abc\n")
      answer(:in_progress, "")
      answer(:command_status, "Success\n")
      answer(:containers, rows("website" => REVISION, "cms" => REVISION))
      answer(:backups, "7\t2026-11-20T10:00:00+00:00\n")
    end

    def rows(revisions)
      revisions.map { |name, revision| "#{name}\t#{REGISTRY}/widget-#{name}:#{name}-old\t#{revision}\tUp 3 minutes\n" }.join
    end
  end

  # A registry in which a console domain attaches Deploy and declares no sibling hecksagon for it,
  # so nothing binds Deploy's ports.
  #
  # @return [Hecks::Runtime::Registry]
  def self.deploy_attached_without_sibling
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.bluebook("Console") { aggregate("Session") { identified_by :id } }
      Hecks.hecksagon("Console") { attaches "Deploy" }
    end
    registry
  end

  # Runs the block with a scratch box whose stand-in `aws` is first on `PATH`.
  #
  # @yieldparam box [Box]
  # @return [Object] the block's value
  def self.with_box
    Dir.mktmpdir("box-state") do |dir|
      box = Box.new(dir)
      saved = ENV.to_h.slice(*box.env.keys)
      ENV.update(box.env)
      yield box
    ensure
      box&.env&.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
    end
  end
end

# A scratch box for each example, Hecks booted once in Memory, and the helpers that ask the
# `BoxState` query through the launcher.
RSpec.shared_context "with a scratch box" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  around do |example|
    BoxStateStandIn.with_box do |box|
      @box = box
      example.run
    end
  end

  attr_reader :box

  # Asks the query of the Hecks runtime, or of another one when its launcher words are given.
  def ask(*argv, runtime: @hecks, words: %w[deploy box_roll.box_state])
    Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, program: "hecks", argv: [*words, *argv])
  end

  # The one row the query answers for the scratch project.
  def state = JSON.parse(ask("project=#{box.project}").first).first
end
