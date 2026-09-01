#!/usr/bin/env ruby
# This script tests crash recovery by simulating a crash during database operations
# It should be run as a subprocess

db_path = ARGV[0] || '/tmp/crash_test.rdb'

require 'rubydb'

c1 = RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)
c2 = RubyDB::Catalog::Column.new(:name, :text, null: false)

engine = RubyDB::Storage::Engine.new(db_path)

# Create table
engine.create_table(:users, [c1, c2])

# Insert first row
engine.insert_row(:users, [c1, c2], [1, 'alice'])

# Insert second row
engine.insert_row(:users, [c1, c2], [2, 'bob'])

# Simulate crash: exit without closing/flushing
# The WAL should have these writes, but the pages might not be synced
exit!(99)  # Exit with code 99 to indicate simulated crash
