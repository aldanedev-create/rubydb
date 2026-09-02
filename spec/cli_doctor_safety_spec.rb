# frozen_string_literal: true

require "spec_helper"

RSpec.describe "CLI doctor repair safety" do
  it "does not claim that --fix repaired an unhealthy result" do
    output = Object.new
    messages = []
    output.define_singleton_method(:puts) { |message = "", *_args| messages << message }
    output.define_singleton_method(:json) { |_data| }
    formatter = Object.new
    formatter.define_singleton_method(:format_doctor) { |_data| }

    health = { passed: false, total_count: 1, passed_count: 0,
               checks: [{ name: "Connection", passed: false, errors: ["offline"] }] }
    command = RubyDB::CLI::Commands::Doctor.new(output, formatter)
    allow(RubyDB::Configuration::Config.instance).to receive(:get)
      .with("storage.data_dir").and_return("Z:/missing/rubydb.rdb")
    command.execute(["--fix"], {})

    expect(messages.join(" ")).to include("no changes were made")
    expect(messages.join(" ")).not_to include("Issues fixed")
  end
end
