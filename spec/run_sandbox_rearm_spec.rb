require "spec_helper"

RSpec.describe "a second run of the sandbox" do
  around do |example|
    File.write(File.join(RunSandbox.path("home"), "left-behind"), "x")
    saved = Dir.home
    RunSandbox.disarm!
    example.run
  ensure
    RunSandbox.arm!
    ENV["HOME"] = saved
  end

  it "gets the real environment back when the first ends" do
    expect(Dir.home).not_to start_with(RunSandbox.root)
  end

  it "starts from an empty home" do
    RunSandbox.arm!
    expect(Dir.children(RunSandbox.path("home"))).to be_empty
  end
end
