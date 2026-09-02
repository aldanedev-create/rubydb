# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "final production audit contracts" do
  it "rejects unknown SQL characters instead of skipping them" do
    expect { RubyDB::SQL::Lexer.new("SELECT @ FROM users").tokenize }
      .to raise_error(RubyDB::ParserError, /Unexpected character/)
  end

  it "requires an attached engine for direct WAL replay" do
    Dir.mktmpdir do |dir|
      wal = RubyDB::WAL::WAL.new(dir, recovery: false, auto_checkpoint: false)
      record = RubyDB::WAL::Record.new(:insert, { table: "users", values: {} })

      expect { wal.send(:replay_record, record) }.to raise_error(RubyDB::RecoveryError, /attached engine/)
    ensure
      wal&.shutdown
    end
  end
end
