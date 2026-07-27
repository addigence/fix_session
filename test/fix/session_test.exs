defmodule FIX.SessionTest do
  use ExUnit.Case
  doctest FIX.Session

  test "greets the world" do
    assert FIX.Session.hello() == :world
  end
end
