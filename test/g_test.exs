defmodule GTest do
  use ExUnit.Case
  doctest G

  test "greets the world" do
    assert G.hello() == :world
  end
end
