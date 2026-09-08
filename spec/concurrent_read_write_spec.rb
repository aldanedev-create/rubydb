# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "concurrent engine reads and writes" do
  it "keeps point reads and scans correct while writers append rows" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "read-write.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:payload, :text, null: false)
      ]
      engine.create_table(:events, columns)
      engine.insert_row(:events, columns, id: 1, payload: "stable")

      writer_count = 4
      inserts_per_writer = 50
      reader_count = 4
      reads_per_reader = 100
      start_gate = Queue.new
      errors = Queue.new

      writers = writer_count.times.map do |writer|
        Thread.new do
          start_gate.pop
          inserts_per_writer.times do |offset|
            id = 2 + (writer * inserts_per_writer) + offset
            engine.insert_row(:events, columns, id: id, payload: "writer-#{writer}-#{offset}")
          end
        rescue StandardError => error
          errors << error
        end
      end

      readers = reader_count.times.map do
        Thread.new do
          start_gate.pop
          reads_per_reader.times do
            point_row = engine.select_row(:events, 1, columns)
            raise "stable row disappeared" unless point_row && point_row[:payload] == "stable"

            scanned_row = engine.select_rows(:events, columns, row_id: 1, limit: 1).first
            raise "stable row changed during scan" unless scanned_row && scanned_row[:payload] == "stable"
          end
        rescue StandardError => error
          errors << error
        end
      end

      (writers + readers).size.times { start_gate << true }
      (writers + readers).each(&:join)
      expect(errors).to be_empty
      expect(engine.table_row_count(:events)).to eq(1 + (writer_count * inserts_per_writer))

      engine.close
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      expect(engine.select_rows(:events, engine.table_columns(:events)).size)
        .to eq(1 + (writer_count * inserts_per_writer))
    ensure
      engine&.close if engine&.open?
    end
  end
end
