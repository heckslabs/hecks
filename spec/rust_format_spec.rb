# frozen_string_literal: true

require "spec_helper"
require "hecks/rust_format"

RSpec.describe Hecks::RustFormat do
  it "lays Rust source out as rustfmt does" do
    expect(described_class.call("pub fn a(){let x=1;}\n")).to eq("pub fn a() {\n    let x = 1;\n}\n")
  end

  it "reaches the same text when formatted a second time" do
    once = described_class.call("pub fn a(){let x=1;}\n")

    expect(described_class.call(once)).to eq(once)
  end

  it "leaves source rustfmt cannot parse as it came" do
    broken = "pub struct S { pub r#crate: u8 }\n"

    allow($stderr).to receive(:write)

    expect(described_class.call(broken)).to eq(broken)
  end

  it "warns when it leaves source unformatted" do
    expect { described_class.call("pub struct S { pub r#crate: u8 }\n") }.to output(/could not format/).to_stderr
  end

  it "formats only the paths that are Rust source" do
    files = described_class.files("/a/b.rs" => "fn a(){}\n", "/a/b.json" => "{ }\n")

    expect(files).to eq("/a/b.rs" => "fn a() {}\n", "/a/b.json" => "{ }\n")
  end
end
