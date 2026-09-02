# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::History::History do
  it "persists changes and reconstructs point-in-time state" do
    Dir.mktmpdir do |dir|
      first_time = Time.utc(2024, 1, 1, 0, 0, 0)
      second_time = first_time + 60
      history = described_class.new(nil, history_dir: dir)
      history.record(
        table_name: "users", row_id: 1, operation: :insert,
        new_values: { id: 1, name: "old" }, timestamp: first_time
      )
      history.record(
        table_name: "users", row_id: 1, operation: :update,
        old_values: { name: "old" }, new_values: { name: "new" }, timestamp: second_time
      )

      before_update = history.query_as_of("users", first_time + 30)
      expect(before_update[:rows]).to eq([{ id: 1, name: "old" }])
      expect(history.query_version("users", 1, second_time)[:data]).to eq(id: 1, name: "new")
      expect(history.query_between("users", first_time, second_time).size).to eq(2)

      reopened = described_class.new(nil, history_dir: dir)
      expect(reopened.query_history("users", 1)[:history].size).to eq(2)
    end
  end
end
