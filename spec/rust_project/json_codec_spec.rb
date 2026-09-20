require "spec_helper"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/json_codec"

# Found live, tonight: `Attendee#news_signup` (`attribute :news_signup,
# TrueClass, default: false`) generated with no default fallback at
# all, refusing a real `Registration.Request` that simply omitted the
# key (an unchecked HTML checkbox's own real submission shape) with
# `"Attendee.news_signup expects TrueClass, got nil"` instead of
# filling in `false`. `scalar_from_json_expr`'s own `if default` check
# is a plain Ruby truthiness test, and a `TrueClass`/`FalseClass`
# attribute's own declared default can legitimately be `false` — Ruby
# treats that identically to "no default was passed at all," so every
# `default: false` attribute silently fell back to the required-field
# branch. No pre-existing String/Integer/Float default (`""`/`0`/`0.0`
# are all truthy in Ruby) could ever have surfaced this; it took the
# first boolean attribute with a `false` default to reach it.
RSpec.describe RustProjection::Projector do
  describe ".scalar_from_json_expr" do
    it "falls back to a declared `default: false` when the key is absent, instead of refusing" do
      rendered = described_class.scalar_from_json_expr("Attendee", "news_signup", "TrueClass", default: false)

      expect(rendered).to include("None => false")
      expect(rendered).not_to include("expects TrueClass, got nil")
    end

    it "falls back to a declared `default: true` the same way" do
      rendered = described_class.scalar_from_json_expr("Attendee", "first_time", "TrueClass", default: true)

      expect(rendered).to include("None => true")
    end

    it "still refuses an absent key when no default is declared at all" do
      rendered = described_class.scalar_from_json_expr("Attendee", "email", "String", default: nil)

      expect(rendered).to include("expects String, got nil")
      expect(rendered).not_to include("None =>")
    end

    it "keeps falling back for an ordinary truthy default (String/Integer/Float unaffected)" do
      expect(described_class.scalar_from_json_expr("PositiveMoney", "currency", "String", default: "USD"))
        .to include(%(None => "USD".to_string()))
      expect(described_class.scalar_from_json_expr("Countdown", "seconds", "Integer", default: 0))
        .to include("None => 0")
    end
  end
end
