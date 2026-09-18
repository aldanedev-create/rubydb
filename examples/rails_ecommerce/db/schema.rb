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

ActiveRecord::Schema[7.2].define(version: 2026_09_18_000000) do
  create_table "customers", id: :integer, force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["email"], name: "idx_customers_email", unique: true
  end

  create_table "order_items", id: :integer, force: :cascade do |t|
    t.integer "order_id", null: false
    t.integer "product_id", null: false
    t.integer "quantity", default: 1, null: false
    t.integer "unit_price_cents", default: 0, null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["order_id", "product_id"], name: "idx_order_items_order_product", unique: true
    t.index ["order_id"], name: "idx_order_items_order_id"
    t.index ["product_id"], name: "idx_order_items_product_id"
  end

  create_table "orders", id: :integer, force: :cascade do |t|
    t.integer "customer_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["customer_id", "created_at"], name: "idx_orders_customer_created"
    t.index ["status"], name: "idx_orders_status"
  end

  create_table "products", id: :integer, force: :cascade do |t|
    t.string "name", null: false
    t.string "sku", null: false
    t.string "category", null: false
    t.integer "price_cents", default: 0, null: false
    t.integer "stock", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["active", "category", "price_cents"], name: "idx_products_catalog"
    t.index ["sku"], name: "idx_products_sku", unique: true
  end

  add_foreign_key "order_items", "orders", name: "fk_order_items_to_orders"
  add_foreign_key "order_items", "products", name: "fk_order_items_to_products"
  add_foreign_key "orders", "customers", name: "fk_orders_to_customers"
end
