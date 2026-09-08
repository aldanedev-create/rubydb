# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::WAL::Writer do
  it "fails subsequent writes visibly after an asynchronous flush failure" do
    Dir.mktmpdir("rubydb-wal-writer") do |dir|
      writer = described_class.new(dir, async: false)
      failure = IOError.new("simulated asynchronous flush failure")
      writer.instance_variable_set(:@background_error, failure)

      expect(writer.stats[:last_background_error]).to eq("simulated asynchronous flush failure")
      expect { writer.flush }.to raise_error(IOError, /asynchronous flush failure/)
      expect { writer.write_record(RubyDB::WAL::Record.new(:insert, { id: 1 })) }
        .to raise_error(IOError, /asynchronous flush failure/)
    ensure
      writer&.shutdown
    end
  end
end
