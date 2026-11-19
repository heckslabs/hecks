require "json"
require "securerandom"
require "hecks/hecks/adapters/github_pull_requests"

# Stand-ins for the ports a boarding and a `ReviewRequest.Close` reach. GitHub is the real
# `GithubPullRequests` adapter over a recorder of `gh` arguments, whose sweep answers one closed
# pull request; the train answers `queued`; every other port refuses as quiet.
module ReviewRequestStandIns
  # @return [Array<Array<String>>] the `gh` arguments the adapter sent
  def gh_calls = @gh_calls ||= []

  # @return [Array<Hecks::Runtime::Event>] the events the command and its policies recorded
  def dispatched(command, **attrs)
    registry = @hecks.registry
    before = registry.event_log.size
    Hecks::Runtime::AdapterLookup.standing_in(method(:stand_in)) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::#{command}", run: { value: SecureRandom.uuid }, **attrs)
    end
    registry.event_log.drop(before)
  end

  # @return [Array<Hecks::Runtime::Event>] what one confirmed boarding recorded
  def board = dispatched("SendTrain.Board", confirm: { value: true })

  # @return [Array<Hecks::Runtime::Event>] what closing pull request #7 with a comment recorded
  def close(confirm: true)
    dispatched("ReviewRequest.Close", number: { value: "7" }, comment: { value: "superseded by #9" },
                                      confirm: { value: confirm })
  end

  private

  def stand_in(port, _asked)
    case port
    when "GitHubPullRequests" then sweeping_github
    when "Train" then queuing_train
    else quiet_port
    end
  end

  def sweeping_github
    github = Hecks::Adapters::GithubPullRequests.new(runner: method(:gh))
    github.define_singleton_method(:tidy) { |**| { report: { value: "closed #7: superseded by #9" } } }
    github
  end

  def gh(args)
    gh_calls << args
    args.first(2) == %w[pr view] ? [JSON.generate("state" => "OPEN"), "", true] : ["", "", true]
  end

  def queuing_train
    Object.new.tap do |port|
      port.define_singleton_method(:carry) do |**|
        { outcome: { value: "queued" }, checkout: { value: "/tmp/co" }, boarded: { value: "a" * 40 },
          commits: { value: 1 }, report: { value: "queued #9" } }
      end
    end
  end

  def quiet_port
    Object.new.tap do |port|
      port.define_singleton_method(:method_missing) { |*| raise Hecks::Adapters::ConsoleCapture::Failure, "quiet" }
      port.define_singleton_method(:respond_to_missing?) { |*| true }
    end
  end
end
