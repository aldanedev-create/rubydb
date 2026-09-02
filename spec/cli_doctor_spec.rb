# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::CLI::Commands::Doctor do
  it "reports live database checks instead of hardcoded results" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doctor.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      engine.close
      allow(RubyDB::Configuration::Config.instance).to receive(:get)
        .with("storage.data_dir").and_return(path)

      output = Object.new
      captured = nil
      output.define_singleton_method(:json) { |data| captured = data }
      formatter = Object.new
      formatter.define_singleton_method(:format_doctor) { |_data| }

      described_class.new(output, formatter).execute([], json: true)

      expect(captured[:checks].map { |check| check[:name] }).to include("Connection", "Storage", "WAL", "Indexes")
      expect(captured[:checks]).not_to include(hash_including(name: "Indexes", passed: false))
    end
  end
end
