defmodule Notifications.Delivery.OwnershipTransferTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Delivery.{Content, Recipients, RepoMock}
  alias Notifications.Events.Event

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp event(status) do
    %Event.OwnershipTransferUpdated{
      event_id: "event-1",
      occurred_at: ~U[2026-11-10 19:00:00Z],
      transfer_id: "transfer-1",
      server_id: "server-1",
      from_user_id: "owner-1",
      to_user_id: "member-1",
      status: status,
      created_at: ~U[2026-11-10 18:00:00Z],
      resolved_at: nil
    }
  end

  test "notifies only the recipient while the offer is pending" do
    assert Recipients.for_ownership_transfer(event("pending")) ==
             {:ok, %{"member-1" => :transfer}}
  end

  test "notifies the previous owner when the recipient answers or the offer expires" do
    for status <- ~w(accepted rejected expired) do
      assert Recipients.for_ownership_transfer(event(status)) ==
               {:ok, %{"owner-1" => :transfer}}
    end
  end

  test "does not notify anybody when the owner cancels" do
    assert Recipients.for_ownership_transfer(event("cancelled")) == {:ok, %{}}
  end

  defp names do
    expect(RepoMock, :get_server_names, fn ["server-1"] -> {:ok, %{"server-1" => "Mi Server"}} end)

    expect(RepoMock, :get_user_names, 2, fn ids ->
      {:ok, Map.take(%{"owner-1" => "Ana", "member-1" => "Beto"}, ids)}
    end)
  end

  test "builds the offer notification with the owner's and the server's names" do
    names()

    assert Content.build(event("pending")) ==
             {:ok,
              %{
                title: "Transferencia de propiedad",
                body: "Ana quiere transferirte la propiedad de Mi Server",
                data: %{
                  "transfer_id" => "transfer-1",
                  "server_id" => "server-1",
                  "status" => "pending"
                }
              }}
  end

  test "builds the answer notifications for the previous owner" do
    for {status, body} <- [
          {"accepted", "Beto aceptó ser el nuevo dueño de Mi Server"},
          {"rejected", "Beto rechazó ser el nuevo dueño de Mi Server"},
          {"expired", "La transferencia de Mi Server venció sin respuesta"}
        ] do
      names()
      assert {:ok, %{body: ^body}} = Content.build(event(status))
    end
  end

  test "falls back to generic names when the replicas don't know them" do
    expect(RepoMock, :get_server_names, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :get_user_names, 2, fn _ids -> {:ok, %{}} end)

    assert {:ok, %{body: "Usuario quiere transferirte la propiedad de Servidor"}} =
             Content.build(event("pending"))
  end
end
