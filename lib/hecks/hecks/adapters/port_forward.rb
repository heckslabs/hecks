# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Adapters
    # The `Session` port's adapter: opens an SSM port forward from this machine to a private host.
    #
    # The forward runs in the background, so the command returns while it stays open. Its output
    # goes to a log under `~/.hecks/tunnels`, named after the tunnel.
    class PortForward
      # The region the instance lives in.
      REGION = "us-east-1"

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Starts the forward and returns once it is running in the background.
      #
      # @param held [Hash] the `Tunnel` record: `name`, `instance`, `host`, `remote_port`, `local_port`
      # @return [Hash{Symbol => String}] `output:` what was forwarded, and where its log is
      def forward(**held)
        log = log_path(plain(held[:name]))
        pid = Process.spawn(*session_argv(held), out: log, err: log, pgroup: true)
        Process.detach(pid)
        { output: "forwarding localhost:#{plain(held[:local_port])} to #{plain(held[:host])}:" \
                  "#{plain(held[:remote_port])} through #{plain(held[:instance])} (pid #{pid}, log #{log})" }
      end

      private

      # @return [Array<String>] the `aws` command that starts the forward
      def session_argv(held)
        parameters = { host: [plain(held[:host])], portNumber: [plain(held[:remote_port]).to_s],
                       localPortNumber: [plain(held[:local_port]).to_s] }
        ["aws", "ssm", "start-session", "--region", REGION, "--target", plain(held[:instance]),
         "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
         "--parameters", JSON.generate(parameters)]
      end

      # @return [String] the log file for a tunnel, created with its directory
      def log_path(name)
        dir = File.join(Dir.home, ".hecks", "tunnels")
        FileUtils.mkdir_p(dir)
        File.join(dir, "#{name}.log")
      end

      # A held value is a plain value, a value object, or the hash a value object is held as.
      def plain(value)
        return value[:value] if value.is_a?(Hash) && value.key?(:value)

        value.respond_to?(:value) ? value.value : value
      end
    end
  end
end
