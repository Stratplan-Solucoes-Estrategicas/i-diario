class AddDailyFrequencyCompensationToDailyFrequencies < ActiveRecord::Migration[5.0]
  disable_ddl_transaction!

  def change
    add_reference :daily_frequencies, :daily_frequency_compensation,
                   foreign_key: true, index: { algorithm: :concurrently }
  end
end
