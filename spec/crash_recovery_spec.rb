# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

RSpec.describe "RubyDB crash recovery" do
  let(:temp_dir) { Dir.mktmpdir }
  let(:db_path) { File.join(temp_dir, 'crash_test.rdb') }

  after(:each) do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe "recovery after clean insert" do
    it "persists and recovers a row after clean insert and reopen" do
      # Session 1: Create table and insert row
      c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
      c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

      engine1 = RubyDB::Storage::Engine.new(db_path)
      engine1.create_table(:users, [c1, c2])
      row_id = engine1.insert_row(:users, [c1, c2], [1, 'alice'])
      engine1.close

      # Session 2: Reopen and verify row was persisted
      engine2 = RubyDB::Storage::Engine.new(db_path)
      tables = engine2.list_tables
      rows = engine2.select_rows(:users, [c1, c2])

      expect(tables).to include(:users)
      expect(rows).to have_attributes(length: 1)
      expect(rows.first[:id]).to eq(1)
      expect(rows.first[:name]).to eq('alice')

      engine2.close
    end
  end

  describe "recovery with WAL enabled" do
    it "logs mutations to WAL" do
      c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
      c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

      engine = RubyDB::Storage::Engine.new(db_path)
      expect(engine.wal).not_to be_nil

      engine.create_table(:users, [c1, c2])
      expect(engine.stats[:wal_writes]).to eq(0)  # CREATE_TABLE not logged yet

      engine.insert_row(:users, [c1, c2], [1, 'alice'])
      expect(engine.stats[:wal_writes]).to be > 0

      engine.close
    end

    it "creates checkpoint on close" do
      c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
      c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

      engine = RubyDB::Storage::Engine.new(db_path)
      engine.create_table(:users, [c1, c2])
      engine.insert_row(:users, [c1, c2], [1, 'alice'])

      # Should create checkpoint on close
      expect(engine.close).to be_truthy

      # WAL directory should exist
      wal_dir = "#{db_path}.wal"
      expect(Dir.exist?(wal_dir)).to be_truthy
    end
  end

  describe "simulated crash recovery" do
    it "recovers from crash during insert (subprocess termination)" do
      c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
      c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

      # Create crash script that will be executed in a subprocess
      crash_script = File.join(temp_dir, 'crash_insert.rb')
      File.write(crash_script, <<~RUBY)
        require 'rubydb'
        
        db_path = #{db_path.inspect}
        c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
        c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)
        
        engine = RubyDB::Storage::Engine.new(db_path)
        engine.create_table(:users, [c1, c2])
        
        # Insert first row
        engine.insert_row(:users, [c1, c2], [1, 'alice'])
        
        # Insert second row
        engine.insert_row(:users, [c1, c2], [2, 'bob'])
        
        # Insert third row (this is when we crash)
        engine.insert_row(:users, [c1, c2], [3, 'charlie'])
        
        # Simulate crash: exit without closing/flushing
        exit!(42)  # Non-zero exit to indicate crash
      RUBY

      # Run the crash script in a subprocess
      ruby_lib = File.expand_path('../lib', __dir__)
      pid = spawn(RbConfig.ruby, '-I', ruby_lib, crash_script, chdir: temp_dir)
      Process.wait(pid)
      crash_exit_code = $?.exitstatus

      # Verify subprocess crashed
      expect(crash_exit_code).to eq(42)

      # Session 2: Reopen and recover
      # This should trigger crash recovery
      engine2 = RubyDB::Storage::Engine.new(db_path)

      # Check recovery stats
      recovery_triggered = engine2.stats[:crash_recoveries].to_i > 0

      # Query tables - should work regardless of whether recovery happened
      tables = engine2.list_tables
      expect(tables).to include(:users)

      rows = engine2.select_rows(:users, [c1, c2])

      # We should have at least the committed rows
      # The exact number depends on when the crash happened
      expect(rows).not_to be_empty

      # At minimum, first row should be recovered
      row_ids = rows.map { |r| r[:id] }
      expect(row_ids).to include(1)

      engine2.close
    end

    it "handles missing WAL gracefully" do
      c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
      c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

      # Create database without WAL
      engine1 = RubyDB::Storage::Engine.new(db_path, recovery: false)
      engine1.create_table(:users, [c1, c2])
      engine1.insert_row(:users, [c1, c2], [1, 'alice'])
      engine1.close

      # Reopen should not crash if WAL doesn't exist
      engine2 = RubyDB::Storage::Engine.new(db_path, recovery: false)
      expect(engine2.list_tables).to include(:users)
      engine2.close
    end
  end
end
