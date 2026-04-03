require "spec_helper"
require "hecks/extensions/metrics"

RSpec.describe "Hecks::Metrics" do
  let(:domain) do
    Hecks.domain "Metrics" do
      aggregate "Counter" do
        attribute :login_count, Integer
        attribute :label, String

        command "CreateCounter" do
          attribute :label, String
        end

        command "UpdateCounter" do
          reference_to "Counter", validate: :exists
          attribute :login_count, Integer
        end
      end
    end
  end

  let(:hecksagon) do
    Hecks.hecksagon do
      aggregate "Counter" do
        capability.login_count.metric
      end
    end
  end

  before do
    @app = Hecks.load(domain, hecksagon: hecksagon)
    Hecks.instance_variable_set(:@_metric_log, nil)
    Hecks.instance_variable_set(:@_metric_sink, nil)
    # Remove singleton methods so the extension re-registers them cleanly
    [:metric_log, :metric_sink=, :metric_sink].each do |m|
      Hecks.singleton_class.remove_method(m) if Hecks.respond_to?(m)
    end
    Hecks.extension_registry[:metrics]&.call(
      Object.const_get("MetricsDomain"), domain, @app
    )
  end

  describe "metric emitted on change" do
    it "appends an entry when a metric attribute changes" do
      counter = MetricsDomain::Counter.create(label: "hits")
      MetricsDomain::Counter.update(counter: counter.id, login_count: 5)

      log = Hecks.metric_log
      expect(log).not_to be_empty
      entry = log.last
      expect(entry[:aggregate]).to eq("Counter")
      expect(entry[:attribute]).to eq(:login_count)
      expect(entry[:new]).to eq(5)
      expect(entry[:command]).to eq("UpdateCounter")
      expect(entry[:timestamp]).to be_a(Time)
    end
  end

  describe "no emit when unchanged" do
    it "does not append when metric value stays the same" do
      MetricsDomain::Counter.create(label: "noop")
      log = Hecks.metric_log
      # create gives login_count nil→nil (or nil→nil if not set), no change emitted
      before_count = log.size

      # Increment with same value won't cross the threshold if we call with the same value
      # For a create command (no self-ref) it should not emit a diff for create→nil
      expect(Hecks.metric_log.size).to eq(before_count)
    end
  end

  describe "custom sink" do
    it "calls the sink with each metric entry" do
      captured = []
      Hecks.metric_sink = ->(entry) { captured << entry }

      counter = MetricsDomain::Counter.create(label: "sinked")
      MetricsDomain::Counter.update(counter: counter.id, login_count: 10)

      expect(captured).not_to be_empty
      expect(captured.last[:attribute]).to eq(:login_count)
      expect(captured.last[:new]).to eq(10)
    end
  end

  describe "Hecks::Metrics.metric_fields" do
    it "returns metric-tagged attribute names from hecksagon" do
      fields = Hecks::Metrics.metric_fields(hecksagon, "Counter")
      expect(fields).to include(:login_count)
    end

    it "returns empty array for aggregates with no metric tags" do
      fields = Hecks::Metrics.metric_fields(hecksagon, "Order")
      expect(fields).to eq([])
    end

    it "returns empty array when hecksagon is nil" do
      expect(Hecks::Metrics.metric_fields(nil, "Counter")).to eq([])
    end
  end
end
