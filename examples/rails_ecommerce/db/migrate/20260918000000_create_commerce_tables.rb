# frozen_string_literal: true

class CreateCommerceTables < ActiveRecord::Migration[7.2]
  def change
    create_table :products do |table|
      table.string :name, null: false
      table.string :sku, null: false
      table.string :category, null: false
      table.integer :price_cents, null: false, default: 0
      table.integer :stock, null: false, default: 0
      table.boolean :active, null: false, default: true
      table.timestamps
    end
    add_index :products, :sku, unique: true
    add_index :products, [:active, :category, :price_cents], name: "idx_products_catalog"

    create_table :customers do |table|
      table.string :name, null: false
      table.string :email, null: false
      table.timestamps
    end
    add_index :customers, :email, unique: true

    create_table :orders do |table|
      table.integer :customer_id, null: false
      table.string :status, null: false, default: "pending"
      table.integer :total_cents, null: false, default: 0
      table.timestamps
    end
    add_index :orders, [:customer_id, :created_at], name: "idx_orders_customer_created"
    add_index :orders, :status

    create_table :order_items do |table|
      table.integer :order_id, null: false
      table.integer :product_id, null: false
      table.integer :quantity, null: false, default: 1
      table.integer :unit_price_cents, null: false, default: 0
      table.timestamps
    end
    add_index :order_items, :order_id
    add_index :order_items, :product_id
    add_index :order_items, [:order_id, :product_id], unique: true, name: "idx_order_items_order_product"

    add_foreign_key :orders, :customers, column: :customer_id
    add_foreign_key :order_items, :orders, column: :order_id
    add_foreign_key :order_items, :products, column: :product_id
  end
end
