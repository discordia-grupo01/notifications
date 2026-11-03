defmodule Notifications.Delivery.PrivateCallTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Delivery.{Content, Recipients, RepoMock}
  alias Notifications.Events.Event

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp event(status) do
    %Event.PrivateCall{
      event_id: "event-1",
      occurred_at: ~U[2026-11-03 19:00:00Z],
      call_id: "call-1",
      conversation_id: "conversation-1",
      caller_id: "caller-1",
      recipient_id: "recipient-1",
      status: status
    }
  end

  test "notifies only the recipient while the call is ringing" do
    assert Recipients.for_private_call(event("ringing")) ==
             {:ok, %{"recipient-1" => :call}}
  end

  test "notifies the caller when a call is rejected, missed or ended" do
    for status <- ~w(rejected missed ended) do
      assert Recipients.for_private_call(event(status)) ==
               {:ok, %{"caller-1" => :call}}
    end
  end

  test "builds an incoming call notification" do
    expect(RepoMock, :get_user_names, fn ["caller-1"] -> {:ok, %{"caller-1" => "Ana"}} end)

    assert Content.build(event("ringing")) ==
             {:ok,
              %{
                title: "Llamada de voz",
                body: "Ana te está llamando",
                data: %{
                  "call_id" => "call-1",
                  "conversation_id" => "conversation-1",
                  "caller_id" => "caller-1",
                  "recipient_id" => "recipient-1",
                  "status" => "ringing"
                }
              }}
  end
end
