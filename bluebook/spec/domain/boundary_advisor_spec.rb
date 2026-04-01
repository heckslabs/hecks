require "spec_helper"

RSpec.describe "Boundary advisor warnings" do
  def warnings_for(domain)
    v = Hecks::Validator.new(domain)
    v.valid?
    v.warnings
  end

  def valid?(domain)
    Hecks::Validator.new(domain).valid?
  end

  describe "SingleAttributeAggregate" do
    it "warns when aggregate has 1 attribute and no VOs or entities" do
      domain = Hecks.domain "Test" do
        aggregate "Color" do
          attribute :hex, String
          command "CreateColor" do
            attribute :hex, String
          end
        end
      end

      warns = warnings_for(domain)
      expect(warns).to include(/Color has only 1 attribute and no value objects or entities/)
    end

    it "does not warn when aggregate has 1 attribute but has value objects" do
      domain = Hecks.domain "Test" do
        aggregate "Color" do
          attribute :hex, String

          value_object "Shade" do
            attribute :name, String
          end

          command "CreateColor" do
            attribute :hex, String
          end
        end
      end

      warns = warnings_for(domain)
      expect(warns).not_to include(/Color has only 1 attribute/)
    end

    it "does not warn when aggregate has 2 or more attributes" do
      domain = Hecks.domain "Test" do
        aggregate "Color" do
          attribute :hex, String
          attribute :name, String
          command "CreateColor" do
            attribute :hex, String
          end
        end
      end

      warns = warnings_for(domain)
      expect(warns).not_to include(/Color has only 1 attribute/)
    end

    it "does not affect valid? result" do
      domain = Hecks.domain "Test" do
        aggregate "Color" do
          attribute :hex, String
          command "CreateColor" do
            attribute :hex, String
          end
        end
      end

      expect(valid?(domain)).to be true
    end
  end

  describe "TooManyCommands" do
    def domain_with_commands(count)
      Hecks.domain "Test" do
        aggregate "Order" do
          attribute :name, String
          count.times do |i|
            command "DoThing#{i}" do
              attribute :name, String
            end
          end
        end
      end
    end

    it "does not warn for 9 commands" do
      warns = warnings_for(domain_with_commands(9))
      expect(warns).not_to include(/Order has \d+ commands/)
    end

    it "warns for exactly 10 commands" do
      warns = warnings_for(domain_with_commands(10))
      expect(warns).to include(/Order has 10 commands -- consider splitting/)
    end

    it "warns for more than 10 commands" do
      warns = warnings_for(domain_with_commands(12))
      expect(warns).to include(/Order has 12 commands -- consider splitting/)
    end

    it "does not affect valid? result" do
      expect(valid?(domain_with_commands(10))).to be true
    end
  end
end
