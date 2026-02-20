defmodule Jido.ClaudeTest do
  use ExUnit.Case, async: true

  describe "Jido.Claude" do
    test "returns version" do
      assert Jido.Claude.version() == "0.1.0"
    end
  end
end
