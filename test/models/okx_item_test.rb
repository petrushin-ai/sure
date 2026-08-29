require "test_helper"

class OkxItemTest < ActiveSupport::TestCase
  setup { @family = families(:dylan_family) }

  test "supports multiple named keys but rejects a duplicate active key in one family" do
    first = OkxItem.create!(family: @family, name: "OKX A", api_key: "key-a", api_secret: "secret", passphrase: "phrase")
    second = OkxItem.new(family: @family, name: "OKX B", api_key: "key-a", api_secret: "other", passphrase: "other")

    refute second.valid?
    assert_includes second.errors[:api_key], "has already been taken"

    first.update!(scheduled_for_deletion: true)
    assert second.valid?
  end

  test "requires all three credentials" do
    item = OkxItem.new(family: @family, name: "OKX", api_key: "k", api_secret: "s")
    refute item.valid?
    assert item.errors[:passphrase].any?
  end
end
