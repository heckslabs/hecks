# frozen_string_literal: true

module Hecks
  module Adapters
    # The settings a credential-free session starts with: an `env` block that blanks or redirects
    # every variable and file a GitHub, AWS, 1Password, SSH or git credential is read through, and
    # `permissions.deny` rules that keep the model's own tools off the credential files and the
    # commands that print a secret.
    #
    # It is accident prevention, not isolation. The `env` reaches the session's commands, which a
    # script can undo, and a deny rule matches a command's prefix, so `/usr/bin/security` or
    # `sh -c` passes it. Only a sandbox the process cannot leave keeps a same-user process from
    # the keychain. Which sessions are scrubbed is the Tickets world's (`session_credentials`); this
    # holds only what a scrub sets.
    module CredentialScrub
      # The variables a credential is passed in, set empty.
      BLANK = %w[GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
                 AWS_SESSION_TOKEN AWS_PROFILE OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_TOKEN SSH_AUTH_SOCK
                 GIT_ASKPASS].freeze

      # The variables that point a tool away from where it keeps a credential. `GIT_CONFIG_*`
      # adds one `credential.helper` entry whose empty value clears the helper list, so git asks no
      # keychain; `GH_CONFIG_DIR` names a directory that holds no login.
      REDIRECTED = {
        "AWS_SHARED_CREDENTIALS_FILE" => File::NULL,
        "AWS_CONFIG_FILE"             => File::NULL,
        "GIT_CONFIG_COUNT"            => "1",
        "GIT_CONFIG_KEY_0"            => "credential.helper",
        "GIT_CONFIG_VALUE_0"          => "",
        "GIT_TERMINAL_PROMPT"         => "0",
        "OP_BIOMETRIC_UNLOCK_ENABLED" => "false"
      }.freeze

      # Where `GH_CONFIG_DIR` points, under the home directory: a directory that holds no login.
      GH_CONFIG = ".claude/hecks-dev/no-credentials/gh"

      # The tool rules a scrubbed session is refused: the credential files, and the commands that
      # print a secret.
      DENY = ["Read(~/.aws/**)", "Read(~/.config/gh/**)", "Read(~/.config/op/**)", "Read(~/.ssh/**)",
              "Bash(security:*)", "Bash(op:*)", "Bash(gh auth token:*)"].freeze

      module_function

      # @param home [String] the home directory `GH_CONFIG_DIR` is placed under
      # @return [Hash{String => String}] the scrub's variables
      def environment(home: Dir.home)
        BLANK.to_h { |name| [name, ""] }.merge(REDIRECTED, "GH_CONFIG_DIR" => File.join(home, GH_CONFIG))
      end

      # @param block [Hash] a settings block, its `env` the session's own variables
      # @param home [String] the home directory `GH_CONFIG_DIR` is placed under
      # @return [Hash] the block with the scrub's variables over its `env` and the deny rules added
      def onto(block, home: Dir.home)
        block.merge("env"         => block.fetch("env", {}).merge(environment(home: home)),
                    "permissions" => { "deny" => DENY.dup })
      end
    end
  end
end
