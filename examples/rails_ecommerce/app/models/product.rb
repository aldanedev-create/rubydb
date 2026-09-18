# frozen_string_literal: true

class Product < ApplicationRecord
  has_many :order_items, dependent: :restrict_with_exception
  has_many :orders, through: :order_items

  validates :name, :sku, :category, presence: true
  validates :sku, uniqueness: true
  validates :price_cents, numericality: {greater_than_or_equal_to: 0}
  validates :stock, numericality: {greater_than_or_equal_to: 0}

  scope :active, -> { where(active: true) }
  scope :in_category, ->(category) { category.present? ? where(category: category) : all }
end
