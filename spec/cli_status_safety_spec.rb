# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "CLI status safety" do
  it "reports live database state without fabricated replication or branch data" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "status.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      engine.close
      allow(RubyDB::Configuration::Config.instance).to receive(:get)
        .with("storage.data_dir").and_return(path)
      output = Object.new
      captured = nil
      output.define_singleton_method(:json) { |data| captured = data }
      formatter = Object.new
      formatter.define_singleton_method(:format_status) { |_data| }

      expect(RubyDB::CLI::Commands::Status.new(output, formatter).execute([], json: true)).to eq(0)
      expect(captured[:status]).to eq("running")
      expect(captured[:replication][:status]).to eq("not_configured")
      expect(captured[:branch][:current]).to eq("unknown")
    end
  end

  it "reports an unavailable database instead of claiming it is running" do
    allow(RubyDB::Configuration::Config.instance).to receive(:get)
      .with("storage.data_dir").and_return("Z:/missing/rubydb.rdb")
    output = Object.new
    captured = nil
    output.define_singleton_method(:json) { |data| captured = data }
    formatter = Object.new
    formatter.define_singleton_method(:format_status) { |_data| }

    RubyDB::CLI::Commands::Status.new(output, formatter).execute([], json: true)

    expect(captured[:status]).to eq("unavailable")
    expect(captured[:error]).not_to be_nil
  end
end
