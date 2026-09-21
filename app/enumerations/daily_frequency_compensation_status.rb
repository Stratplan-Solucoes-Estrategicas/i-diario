# frozen_string_literal: true

class DailyFrequencyCompensationStatus < EnumerateIt::Base
  associate_values :pending, :approved, :rejected
end
