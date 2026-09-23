# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "insert scaling" do
  %i[primary_key unique].each do |constraint|
    it "keeps rows 4,001-5,000 within twice the first 1,000 for #{constraint}" do
      Dir.mktmpdir("rubydb-scaling") do |dir|
        engine = RubyDB::Storage::Engine.new(File.join(dir, "scale.rdb"), auto_cleanup: false,
          accelerator: {mode: :off})
        column = RubyDB::Catalog::Column.new(:id, :integer,
          primary_key: constraint == :primary_key, unique: constraint == :unique, null: false)
        engine.create_table(:items, [column])
        blocks = []
        5.times do |block|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          1000.times { |index| engine.insert_row(:items, [column], {id: block * 1000 + index + 1}) }
          blocks << Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        expect(blocks.last / blocks.first).to be < 2.0
        engine.close
      ensure
        engine&.close
      end
    end
  end
end
