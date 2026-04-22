# Hecks::ShellAdapterError / ShellAdapterTimeoutError
#
# Errors raised by Hecks::Runtime::ShellDispatcher when a shell adapter
# invocation fails. Placed in its own file because the main errors.rb
# already sits at 346 lines and grouping by subsystem keeps each file
# focused.
#
#   raise Hecks::ShellAdapterError.new(
#     "exit 128",
#     adapter: :git_log, exit_status: 128, stderr: "fatal: ..."
#   )
#
module Hecks
  # Raised when a shell adapter exits non-zero (for every output_format
  # except :exit_code, which treats exit status as data rather than
  # failure).
  class ShellAdapterError < Error
    # @return [Symbol] the adapter name that failed
    attr_reader :adapter

    # @return [Integer, nil] the process exit status
    attr_reader :exit_status

    # @return [String, nil] captured stderr (may be truncated by caller)
    attr_reader :stderr

    def initialize(message = nil, adapter: nil, exit_status: nil, stderr: nil)
      @adapter = adapter
      @exit_status = exit_status
      @stderr = stderr
      super(message)
    end

    # Returns structured error data including adapter context.
    #
    # @return [Hash] error data with :error, :message, :adapter, :exit_status, :stderr
    def as_json
      h = super
      h[:adapter] = adapter.to_s if adapter
      h[:exit_status] = exit_status if exit_status
      h[:stderr] = stderr if stderr
      h
    end
  end

  # Raised when a shell adapter invocation runs past its declared timeout.
  class ShellAdapterTimeoutError < ShellAdapterError
    # @return [Integer, nil] the timeout (seconds) that was exceeded
    attr_reader :timeout

    def initialize(message = nil, adapter: nil, timeout: nil)
      @timeout = timeout
      super(message, adapter: adapter)
    end

    def as_json
      h = super
      h[:timeout] = timeout if timeout
      h
    end
  end
end
