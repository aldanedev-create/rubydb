# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "relational constraints" do
  it "evaluates SQL CHECK predicates for symbol-keyed rows" do
    constraint = RubyDB::Constraints::CheckConstraint.new(
      :users, "age >= 18", expression_type: :sql
    )

    expect(constraint.validate(age: 21)).to be(true)
    expect(constraint.validate(age: 17)).to be(false)
  end

  it "evaluates compound, null, boolean, and SQL not-equal predicates" do
    constraint = RubyDB::Constraints::CheckConstraint.new(
      :users, "age >= 18 AND active = true AND deleted_at IS NULL"
    )
    expect(constraint.validate(age: 21, active: true, deleted_at: nil)).to be(true)
    expect(constraint.validate(age: 21, active: false, deleted_at: nil)).to be(false)
    expect(constraint.validate(age: 21, active: true, deleted_at: Time.now)).to be(false)

    alternate = RubyDB::Constraints::CheckConstraint.new(:users, "status <> 'disabled' OR admin = true")
    expect(alternate.validate(status: "active", admin: false)).to be(true)
    expect(alternate.validate(status: "disabled", admin: false)).to be(false)
    expect(alternate.validate(status: "disabled", admin: true)).to be(true)
  end

  it "fails foreign-key validation when the reference lookup cannot prove a match" do
    constraint = RubyDB::Constraints::ForeignKeyConstraint.new(
      :orders, :user_id, :users, :id,
      reference_lookup: ->(_table, conditions) { conditions[:id] == 7 }
    )

    expect(constraint.validate(user_id: 7)).to be(true)
    expect(constraint.validate(user_id: 8)).to be(false)
  end

  it "fails closed when no foreign-key reference lookup is configured" do
    constraint = RubyDB::Constraints::ForeignKeyConstraint.new(:orders, :user_id, :users)

    expect(constraint.validate(user_id: 7)).to be(false)
  end

  it "uses the reference lookup for delete-integrity checks" do
    constraint = RubyDB::Constraints::ForeignKeyConstraint.new(
      :users, :id, :users, :id,
      reference_lookup: ->(_table, conditions) { conditions[:id] == 7 }
    )

    expect(constraint.check_referential_integrity(:users, 7)).to be(false)
    expect(constraint.check_referential_integrity(:users, 8)).to be(true)
    expect(constraint.check_referential_integrity(:orders, 7)).to be(false)
  end

  it "enforces persisted CHECK and FOREIGN KEY definitions at the engine boundary" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "relations.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      parent_columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      child_columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:parent_id, :integer, null: false),
        RubyDB::Catalog::Column.new(:age, :integer, null: false)
      ]
      engine.create_table(:parents, parent_columns)
      engine.create_table(
        :children,
        child_columns,
        constraints: [
          { type: :foreign_key, columns: [:parent_id], reference_table: :parents, reference_columns: [:id] },
          { type: :check, expression: "age >= 18" }
        ]
      )
      engine.insert_row(:parents, parent_columns, [7])
      engine.insert_row(:children, child_columns, [1, 7, 21])

      expect { engine.delete_row(:parents, 1) }
        .to raise_error(RubyDB::DatabaseError, /Cannot delete referenced row/)

      expect { engine.insert_row(:children, child_columns, [2, 99, 21]) }
        .to raise_error(RubyDB::DatabaseError, /Referenced row/)
      expect { engine.insert_row(:children, child_columns, [3, 7, 17]) }
        .to raise_error(RubyDB::DatabaseError, /Check constraint failed/)
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect { reopened.insert_row(:children, child_columns, [4, 99, 21]) }
        .to raise_error(RubyDB::DatabaseError, /Referenced row/)
      reopened.close
    ensure
      engine&.close
      reopened&.close
    end
  end

  it "applies ON DELETE CASCADE to referencing rows" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "cascade.rdb"), auto_vacuum: false)
      parent_columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      child_columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:parent_id, :integer, null: false)
      ]
      engine.create_table(:parents, parent_columns)
      engine.create_table(:children, child_columns, constraints: [
        { type: :foreign_key, columns: [:parent_id], reference_table: :parents,
          reference_columns: [:id], on_delete: :cascade }
      ])
      engine.insert_row(:parents, parent_columns, [7])
      engine.insert_row(:children, child_columns, [1, 7])

      expect(engine.delete_row(:parents, 1)).to be(true)
      expect(engine.select_rows(:children, child_columns, visibility_check: false)).to be_empty
    ensure
      engine&.close if engine&.open?
    end
  end

  it "applies ON DELETE SET NULL to nullable referencing columns" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "set-null.rdb"), auto_vacuum: false)
      parent_columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      child_columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:parent_id, :integer, null: true)
      ]
      engine.create_table(:parents, parent_columns)
      engine.create_table(:children, child_columns, constraints: [
        { type: :foreign_key, columns: [:parent_id], reference_table: :parents,
          reference_columns: [:id], on_delete: :set_null }
      ])
      engine.insert_row(:parents, parent_columns, [7])
      engine.insert_row(:children, child_columns, [1, 7])

      expect(engine.delete_row(:parents, 1)).to be(true)
      rows = engine.select_rows(:children, child_columns, visibility_check: false)
      expect(rows.first["parent_id"] || rows.first[:parent_id]).to be_nil
      engine.close
      engine = RubyDB::Storage::Engine.new(File.join(dir, "set-null.rdb"), auto_vacuum: false)
      rows = engine.select_rows(:children, child_columns, visibility_check: false)
      expect(rows.first["parent_id"] || rows.first[:parent_id]).to be_nil
    ensure
      engine&.close if engine&.open?
    end
  end

  it "applies ON UPDATE CASCADE to referencing rows" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "update-cascade.rdb"), auto_vacuum: false)
      parent_columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      child_columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:parent_id, :integer, null: false)
      ]
      engine.create_table(:parents, parent_columns)
      engine.create_table(:children, child_columns, constraints: [
        { type: :foreign_key, columns: [:parent_id], reference_table: :parents,
          reference_columns: [:id], on_update: :cascade }
      ])
      engine.insert_row(:parents, parent_columns, [7])
      engine.insert_row(:children, child_columns, [1, 7])

      expect(engine.update_row(:parents, 1, { id: 8 })).to be(true)
      row = engine.select_rows(:children, child_columns, visibility_check: false).first
      expect(row["parent_id"] || row[:parent_id]).to eq(8)
    ensure
      engine&.close if engine&.open?
    end
  end

  it "restricts updates that would orphan referencing rows" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "update-restrict.rdb"), auto_vacuum: false)
      parent_columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      child_columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:parent_id, :integer, null: false)
      ]
      engine.create_table(:parents, parent_columns)
      engine.create_table(:children, child_columns, constraints: [
        { type: :foreign_key, columns: [:parent_id], reference_table: :parents,
          reference_columns: [:id], on_update: :restrict }
      ])
      engine.insert_row(:parents, parent_columns, [7])
      engine.insert_row(:children, child_columns, [1, 7])

      expect { engine.update_row(:parents, 1, { id: 8 }) }
        .to raise_error(RubyDB::DatabaseError, /Cannot update referenced row/)
    ensure
      engine&.close if engine&.open?
    end
  end
end
