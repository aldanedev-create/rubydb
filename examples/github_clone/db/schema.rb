# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_09_09_000000) do
  create_table "commits", id: :integer, force: :cascade do |t|
    t.integer "repository_id", null: false
    t.string "sha", null: false
    t.string "message", null: false
    t.string "author", null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["repository_id", "created_at"], name: "idx_commits_repository_id_created_at"
    t.index ["sha"], name: "idx_commits_sha", unique: true
  end

  create_table "issues", id: :integer, force: :cascade do |t|
    t.integer "repository_id", null: false
    t.string "title", null: false
    t.string "body"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["repository_id", "created_at"], name: "idx_issues_repository_id_created_at"
  end

  create_table "repositories", id: :integer, force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["name"], name: "idx_repositories_name", unique: true
  end

  add_foreign_key "commits", "repositories"
  add_foreign_key "issues", "repositories"
end
