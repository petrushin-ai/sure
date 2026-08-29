require "test_helper"

class SyncBinanceJobTest < ActiveJob::TestCase
  test "syncs every active Binance connection" do
    first = mock("first_binance_item")
    second = mock("second_binance_item")
    first.expects(:sync_later).once
    second.expects(:sync_later).once

    relation = mock("active_binance_items")
    relation.stubs(:find_each).multiple_yields([ first ], [ second ])
    BinanceItem.expects(:active).returns(relation)

    SyncBinanceJob.perform_now
  end

  test "records an enqueue failure and continues" do
    family = families(:dylan_family)
    failing = stub(id: "failed-id", family: family)
    failing.stubs(:sync_later).raises(StandardError, "queue unavailable")
    success = mock("successful_binance_item")
    success.expects(:sync_later).once

    relation = mock("active_binance_items")
    relation.stubs(:find_each).multiple_yields([ failing ], [ success ])
    BinanceItem.expects(:active).returns(relation)

    assert_difference "DebugLogEntry.count", 1 do
      SyncBinanceJob.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "binance", entry.provider_key
    assert_equal "failed-id", entry.metadata["binance_item_id"]
  end
end
