# frozen_string_literal: true

class AddTonToOnchainWallets < ActiveRecord::Migration[7.2]
  def up
    add_column :onchain_wallet_items, :toncenter_api_key, :text

    remove_check_constraint :onchain_wallet_accounts,
                            name: "chk_onchain_wallet_accounts_known_asset_kind"
    add_check_constraint :onchain_wallet_accounts,
                         "asset_kind IN ('native', 'erc20', 'spl', 'jetton')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"

    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :contract_address ],
              unique: true,
              where: "asset_kind = 'jetton'",
              name: "index_onchain_wallet_accounts_unique_jetton"
  end

  def down
    remove_index :onchain_wallet_accounts, name: "index_onchain_wallet_accounts_unique_jetton"
    remove_check_constraint :onchain_wallet_accounts,
                            name: "chk_onchain_wallet_accounts_known_asset_kind"
    add_check_constraint :onchain_wallet_accounts,
                         "asset_kind IN ('native', 'erc20', 'spl')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"

    remove_column :onchain_wallet_items, :toncenter_api_key
  end
end
