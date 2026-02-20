defmodule Jido.Claude.CLI.ParserTest do
  use ExUnit.Case, async: true

  alias Jido.Claude.CLI.Parser

  test "event_kind/1 returns nested stream event kind" do
    event = %{"type" => "stream_event", "event" => %{"type" => "content_block_delta"}}
    assert Parser.event_kind(event) == "stream:content_block_delta"
  end

  test "extract_result_text/2 prefers result payload" do
    events = [
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "partial"}]}},
      %{"type" => "result", "result" => "final answer"}
    ]

    assert Parser.extract_result_text(events, nil) == "final answer"
  end

  test "extract_result_text/2 falls back to assistant text and deltas" do
    assistant_only = [
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "assistant answer"}]}}
    ]

    delta_only = [
      %{
        "type" => "stream_event",
        "event" => %{"type" => "content_block_delta", "delta" => %{"text" => "delta answer"}}
      }
    ]

    assert Parser.extract_result_text(assistant_only, nil) == "assistant answer"
    assert Parser.extract_result_text(delta_only, nil) == "delta answer"
  end
end
