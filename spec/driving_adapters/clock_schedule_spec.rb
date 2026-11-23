require "spec_helper"
require "hecks/adapters/driving/clock"

# The three triggers a clock can declare, and the next fire time each answers (ADR 0184).
RSpec.describe Hecks::Adapters::Driving::Clock::Schedule do
  def utc(*parts) = Time.utc(*parts).to_i

  def clock(trigger, expression, zone = nil)
    Hecks::Bluebook::Clock.new(name: "Tick", trigger: trigger, expression: expression, zone: zone, command: "Loan.OpenLoan")
  end

  describe "cron" do
    let(:phoenix_morning) { described_class.for(clock(:cron, "30 6 * * *", "America/Phoenix")) }

    it "reads 30 6 * * * in America/Phoenix as 13:30 UTC in winter" do
      expect(phoenix_morning.next_after(utc(2026, 11, 22, 12))).to eq(utc(2026, 11, 22, 13, 30))
    end

    # Phoenix keeps no daylight saving, so a July morning is 13:30 UTC as well.
    it "reads the same Phoenix morning as 13:30 UTC in summer" do
      expect(phoenix_morning.next_after(utc(2026, 7, 1, 14))).to eq(utc(2026, 7, 2, 13, 30))
    end

    it "follows daylight saving in a zone that keeps it", :aggregate_failures do
      schedule = described_class.for(clock(:cron, "0 9 * * *", "America/New_York"))
      expect(schedule.next_after(utc(2026, 7, 1))).to eq(utc(2026, 7, 1, 13))
      expect(schedule.next_after(utc(2026, 12, 1))).to eq(utc(2026, 12, 1, 14))
    end

    it "runs in UTC when no zone is named" do
      expect(described_class.for(clock(:cron, "0 2 * * *")).next_after(utc(2026, 11, 22, 3))).to eq(utc(2026, 11, 23, 2))
    end

    it "reads steps, ranges and weekdays" do
      expect(described_class.for(clock(:cron, "*/15 9-17 * * 1-5")).next_after(utc(2026, 11, 21, 12))).to eq(utc(2026, 11, 23, 9))
    end

    it "refuses an expression without five fields" do
      expect { described_class.for(clock(:cron, "30 6 * *")) }.to raise_error(ArgumentError, /five fields/)
    end

    it "refuses a zone the machine does not know" do
      expect { described_class.for(clock(:cron, "30 6 * * *", "Mars/Olympus")) }.to raise_error(ArgumentError, /not a time zone/)
    end
  end

  describe "every" do
    it "ticks on whole multiples of the interval" do
      expect(described_class.for(clock(:every, "15m")).next_after(utc(2026, 11, 22, 12, 7))).to eq(utc(2026, 11, 22, 12, 15))
    end

    it "refuses a duration with no unit" do
      expect { described_class.for(clock(:every, "15")) }.to raise_error(ArgumentError, /not a duration/)
    end
  end

  describe "at" do
    let(:schedule) { described_class.for(clock(:at, "2026-11-23T06:30:00-07:00")) }

    it "fires once at its instant, and never after it", :aggregate_failures do
      expect(schedule.next_after(utc(2026, 11, 22))).to eq(utc(2026, 11, 23, 13, 30))
      expect(schedule.next_after(utc(2026, 11, 23, 13, 30))).to be_nil
    end

    it "refuses an instant with no offset" do
      expect { described_class.for(clock(:at, "2026-11-23T06:30:00")) }.to raise_error(ArgumentError, /offset/)
    end
  end
end
