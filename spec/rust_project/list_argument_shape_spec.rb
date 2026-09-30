require "spec_helper"
require_relative "../../rust/project"

# The Rust kernel reads a command's list argument the way the Ruby runtime does: an array (null
# and an absent key are the empty list), and a lone scalar is a TypeMismatch naming the argument.
RSpec.describe "RustProjection list argument shape" do
  let(:attr) { { name: "labels", type: "String", list: true } }
  let(:rhs) do
    RustProjection::Projector.flat_field_rhs("NoteArgs", attr, "labels", {}, false)
  end

  it "reads null and an absent key as the empty list" do
    expect(rhs).to include("Some(crate::kernel::Json::Null) | None => Vec::new()")
  end

  it "refuses a value that is not an array, worded as the Ruby runtime words it" do
    expect(rhs).to include("x.as_array().ok_or_else(")
    expect(rhs).to include("NoteArgs.labels expects list_of(String), got {}")
    expect(rhs).not_to include("and_then(crate::kernel::Json::as_array)")
  end
end
