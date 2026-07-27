defmodule FIX.Session.ConfigTest do
  use ExUnit.Case, async: true

  alias FIX.Session.Config

  @required [
    session_id: :ibkr,
    host: "localhost",
    port: 5001,
    sender_comp_id: "ADDIGENCE",
    target_comp_id: "IBKR"
  ]

  test "applies defaults over the required fields" do
    config = Config.new!(@required)

    assert config.begin_string == "FIX.4.4"
    assert config.heartbeat_interval == 30
    assert config.transport == FIX.Session.Transport.TCP
    assert config.store == FIX.Session.Store.ETS
    assert config.dictionary == FIX.Dictionary.FIX44
    assert config.reset_on_logon == false
  end

  test "store_ref defaults to the configured store module" do
    assert Config.new!(@required).store_ref == FIX.Session.Store.ETS

    config = Config.new!(@required ++ [store: FIX.Session.Store.Memory])
    assert config.store_ref == FIX.Session.Store.Memory
  end

  test "an explicit store_ref wins over the default" do
    config = Config.new!(@required ++ [store_ref: :my_table])

    assert config.store == FIX.Session.Store.ETS
    assert config.store_ref == :my_table
  end

  test "raises on missing required fields" do
    assert_raise ArgumentError, ~r/:sender_comp_id/, fn ->
      Config.new!(Keyword.delete(@required, :sender_comp_id))
    end
  end

  test "raises on unknown fields" do
    assert_raise KeyError, fn -> Config.new!(@required ++ [heartbeat: 30]) end
  end

  test "raises on invalid values" do
    assert_raise ArgumentError, ~r/:port/, fn ->
      Config.new!(Keyword.put(@required, :port, 0))
    end

    assert_raise ArgumentError, ~r/:heartbeat_interval/, fn ->
      Config.new!(@required ++ [heartbeat_interval: -1])
    end

    assert_raise ArgumentError, ~r/:reset_on_logon/, fn ->
      Config.new!(@required ++ [reset_on_logon: "Y"])
    end
  end

  test "accepts zero to disable heartbeats" do
    assert Config.new!(@required ++ [heartbeat_interval: 0]).heartbeat_interval == 0
  end

  test "rejects reset_on_logon at build time until sequence reset is implemented" do
    # A permanent child that can never pass init would take its whole
    # supervision tree down at boot; the config must fail fast instead.
    assert_raise ArgumentError, ~r/:reset_on_logon/, fn ->
      Config.new!(@required ++ [reset_on_logon: true])
    end
  end
end
