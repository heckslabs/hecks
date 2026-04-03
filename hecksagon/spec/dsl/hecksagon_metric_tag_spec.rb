# Hecksagon DSL metric tag spec
#
# Tests that the :metric tag is correctly parsed from the Hecksagon DSL
# and stored in aggregate_capabilities IR.
#
require "spec_helper"

RSpec.describe "Hecksagon DSL metric tag" do
  describe "parsing a single metric tag" do
    it "stores the metric tag for a named attribute" do
      hex = Hecks.hecksagon do
        aggregate "Pizza" do
          capability.order_count.metric
        end
      end

      tags = hex.aggregate_capabilities["Pizza"]
      expect(tags).to include({ attribute: "order_count", tag: :metric })
    end
  end

  describe "parsing multiple metric tags" do
    it "stores all metric-tagged attributes" do
      hex = Hecks.hecksagon do
        aggregate "Account" do
          capability.login_count.metric
          capability.revenue.metric
        end
      end

      tags = hex.aggregate_capabilities["Account"]
      expect(tags).to include({ attribute: "login_count", tag: :metric })
      expect(tags).to include({ attribute: "revenue", tag: :metric })
    end
  end

  describe "mixing metric with other tags" do
    it "stores metric alongside pii on different attributes" do
      hex = Hecks.hecksagon do
        aggregate "Customer" do
          capability.email.pii
          capability.purchase_count.metric
        end
      end

      tags = hex.aggregate_capabilities["Customer"]
      expect(tags).to include({ attribute: "email", tag: :pii })
      expect(tags).to include({ attribute: "purchase_count", tag: :metric })
    end
  end

  describe "Hecks::Metrics.metric_fields integration" do
    it "extracts metric fields from the IR" do
      require "hecks/extensions/metrics"

      hex = Hecks.hecksagon do
        aggregate "Order" do
          capability.item_count.metric
        end
      end

      fields = Hecks::Metrics.metric_fields(hex, "Order")
      expect(fields).to eq([:item_count])
    end
  end
end
