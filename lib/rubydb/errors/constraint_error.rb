# frozen_string_literal: true

module RubyDB
  # Raised when a constraint is violated
  class ConstraintError < Error
    attr_reader :constraint_name, :table_name, :column_name

    def initialize(message = "Constraint violation", constraint_name: nil, table_name: nil, column_name: nil, details: nil)
      super(message, code: ErrorCodes::CONSTRAINT_VIOLATION, details: details)
      @constraint_name = constraint_name
      @table_name = table_name
      @column_name = column_name
    end

    def to_s
      msg = super
      msg = "#{msg} on table #{@table_name}" if @table_name
      msg = "#{msg} column #{@column_name}" if @column_name
      msg = "#{msg} constraint #{@constraint_name}" if @constraint_name
      msg
    end
  end
end