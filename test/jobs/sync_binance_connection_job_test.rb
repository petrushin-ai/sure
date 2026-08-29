require "test_helper"

class SyncBinanceConnectionJobTest < ActiveJob::TestCase
  test "starts one active connection sync" do
    item = binance_items(:one)
    relation = stub(find_by: item)
    BinanceItem.stubs(:active).returns(relation)
    item.expects(:syncing?).returns(false)
    item.expects(:sync_later).once

    assert_nil SyncBinanceConnectionJob.perform_now(item.id)
  end

  test "ignores a connection that is no longer active" do
    item = binance_items(:one)
    relation = stub(find_by: nil)
    BinanceItem.stubs(:active).returns(relation)

    assert_nil SyncBinanceConnectionJob.perform_now(item.id)
  end

  test "does not start a duplicate sync" do
    item = binance_items(:one)
    relation = stub(find_by: item)
    BinanceItem.stubs(:active).returns(relation)
    item.expects(:syncing?).returns(true)
    item.expects(:sync_later).never

    SyncBinanceConnectionJob.perform_now(item.id)
  end
end
