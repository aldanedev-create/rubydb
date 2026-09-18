# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :customer
  has_many :order_items, dependent: :restrict_with_exception
  has_many :products, through: :order_items

  validates :status, inclusion: {in: %w[pending paid shipped cancelled]}
  validates :total_cents, numericality: {greater_than_or_equal_to: 0}

  scope :completed, -> { where(status: %w[paid shipped]) }
end
