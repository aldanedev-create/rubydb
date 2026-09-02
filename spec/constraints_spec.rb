# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Constraints::Validator do
  it "validates a row without deadlocking while resolving table constraints" do
    validator = described_class.new
    validator.add_constraint(
      RubyDB::Constraints::NotNullConstraint.new(:users, :email)
    )

    valid = validator.validate_row({ email: "user@example.com" }, :users)
    invalid = validator.validate_row({ email: nil }, :users)

    expect(valid[:valid]).to be(true)
    expect(invalid[:valid]).to be(false)
    expect(invalid[:errors].first[:type]).to eq(:not_null)
  end

  it "enforces primary-key, unique, and not-null column metadata on writes" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "constraints.rdb")
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:email, :text, unique: true, null: false)
      ]
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, [1, "a@example.com"])

      expect { engine.insert_row(:users, columns, [1, "b@example.com"]) }
        .to raise_error(RubyDB::DatabaseError, /Duplicate/)
      expect { engine.insert_row(:users, columns, [2, nil]) }
        .to raise_error(RubyDB::DatabaseError, /cannot be NULL/)
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect { reopened.insert_row(:users, columns, [1, "c@example.com"]) }
        .to raise_error(RubyDB::DatabaseError, /Duplicate/)
      reopened.close
    ensure
      engine&.close
      reopened&.close
    end
  end
end
