require "hecks"

RSpec.describe "HEC-65: Optimistic Concurrency" do
  let(:es) { Hecks::EventSourcing }

  describe "Concurrency" do
    it "stamps and reads version on an aggregate" do
      aggregate = Struct.new(:id).new(1)
      es::Concurrency.stamp!(aggregate, 3)
      expect(aggregate._version).to eq(3)
      expect(es::Concurrency.version_of(aggregate)).to eq(3)
    end

    it "defaults to version 0 for unstamped aggregates" do
      aggregate = Struct.new(:id).new(1)
      expect(es::Concurrency.version_of(aggregate)).to eq(0)
    end

    it "raises ConcurrencyError on version mismatch" do
      expect {
        es::Concurrency.check!(expected: 2, actual: 3)
      }.to raise_error(Hecks::ConcurrencyError, /Expected version 2/)
    end

    it "passes when versions match" do
      expect {
        es::Concurrency.check!(expected: 3, actual: 3)
      }.not_to raise_error
    end
  end

  describe "VersionCheckStep" do
    let(:domain) do
      Hecks.domain "ConcurrencyTest" do
        aggregate "Widget" do
          attribute :label, String
          command "UpdateWidget" do
            attribute :label, String
          end
        end
      end
    end

    before { @app = Hecks.load(domain) }

    it "is available as a pipeline step" do
      expect(es::VersionCheckStep).to respond_to(:call)
    end
  end
end
