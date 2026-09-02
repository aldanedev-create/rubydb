# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "transaction crash recovery" do
  let(:columns) do
    [
      RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
      RubyDB::Catalog::Column.new(:name, :text, null: false)
    ]
  end

  def run_child(db_path, body)
    script = File.join(File.dirname(db_path), "child_#{Process.pid}_#{rand(1_000_000)}.rb")
    File.write(script, <<~RUBY)
      require "rubydb"
      db_path = #{db_path.inspect}
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:name, :text, null: false)
      ]
      #{body}
    RUBY

    pid = Process.spawn(RbConfig.ruby, "-Ilib", script, chdir: Dir.pwd)
    Process.wait(pid)
    $?.exitstatus
  ensure
    FileUtils.rm_f(script) if script
  end

  it "retains a committed insert after process termination" do
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "committed.rdb")
      status = run_child(db_path, <<~RUBY)
        engine = RubyDB::Storage::Engine.new(db_path)
        engine.create_table(:users, columns)
        transaction_id = engine.begin_transaction
        engine.insert_row(:users, columns, [1, "committed"])
        engine.commit_transaction({ id: transaction_id, active: true })
        exit!(42)
      RUBY

      expect(status).to eq(42)
      engine = RubyDB::Storage::Engine.new(db_path)
      expect(engine.select_rows(:users, columns).map { |row| row[:id] }).to include(1)
      engine.close
    end
  end

  it "removes an uncommitted insert after process termination" do
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "uncommitted.rdb")
      status = run_child(db_path, <<~RUBY)
        engine = RubyDB::Storage::Engine.new(db_path)
        engine.create_table(:users, columns)
        engine.begin_transaction
        engine.insert_row(:users, columns, [1, "uncommitted"])
        exit!(42)
      RUBY

      expect(status).to eq(42)
      engine = RubyDB::Storage::Engine.new(db_path)
      expect(engine.select_rows(:users, columns)).to be_empty
      engine.close
    end
  end

  it "restores the old value after an uncommitted update" do
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "update.rdb")
      setup = RubyDB::Storage::Engine.new(db_path)
      setup.create_table(:users, columns)
      setup.insert_row(:users, columns, [1, "before"])
      setup.close

      status = run_child(db_path, <<~RUBY)
        engine = RubyDB::Storage::Engine.new(db_path)
        engine.begin_transaction
        engine.update_row(:users, 1, { name: "after" })
        exit!(42)
      RUBY

      expect(status).to eq(42)
      engine = RubyDB::Storage::Engine.new(db_path)
      expect(engine.select_rows(:users, columns).first[:name]).to eq("before")
      engine.close
    end
  end

  it "restores an uncommitted delete after process termination" do
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "delete.rdb")
      setup = RubyDB::Storage::Engine.new(db_path)
      setup.create_table(:users, columns)
      setup.insert_row(:users, columns, [1, "before"])
      setup.close

      status = run_child(db_path, <<~RUBY)
        engine = RubyDB::Storage::Engine.new(db_path)
        engine.begin_transaction
        engine.delete_row(:users, 1)
        exit!(42)
      RUBY

      expect(status).to eq(42)
      engine = RubyDB::Storage::Engine.new(db_path)
      expect(engine.select_rows(:users, columns).map { |row| row[:id] }).to include(1)
      engine.close
    end
  end
end
