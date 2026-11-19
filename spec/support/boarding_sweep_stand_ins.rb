# frozen_string_literal: true

require "securerandom"
require "hecks/hecks/adapters/github_pull_requests"

# Stand-ins for the ports a confirmed `SendTrain.Board` reaches: the train answers `queued`,
# GitHub's `tidy` answers one closed pull request (or raises, when `@tidy_refuses` is set), and
# every other port fails as quiet. Nothing reaches git, GitHub or a live store.
module BoardingSweepStandIns
  # @return [Array<Hecks::Runtime::Event>] what one confirmed boarding recorded
  def board
    registry = @hecks.registry
    before = registry.event_log.size
    attrs = { run: { value: SecureRandom.uuid }, confirm: { value: true } }
    Hecks::Runtime::AdapterLookup.standing_in(method(:stand_in)) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::SendTrain.Board", **attrs)
    end
    registry.event_log.drop(before)
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
    refuses = @tidy_refuses
    Object.new.tap do |port|
      port.define_singleton_method(:tidy) do |**|
        raise Hecks::Adapters::ConsoleCapture::Failure, "gh: API rate limit" if refuses

        { report: { value: "closed #7: superseded by #9" } }
      end
    end
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
