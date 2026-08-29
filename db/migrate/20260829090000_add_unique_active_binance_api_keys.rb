class AddUniqueActiveBinanceApiKeys < ActiveRecord::Migration[7.2]
  def change
    add_index :binance_items,
              [ :family_id, :api_key ],
              unique: true,
              where: "scheduled_for_deletion = false",
              name: "idx_binance_items_unique_active_api_key_by_family"
  end
end
