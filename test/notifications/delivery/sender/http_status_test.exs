defmodule Notifications.Delivery.Sender.HttpStatusTest do
  use ExUnit.Case, async: true

  alias Notifications.Delivery.Sender.HttpStatus

  test "known statuses keep their http_<status> reason" do
    assert HttpStatus.reason(400) == :http_400
    assert HttpStatus.reason(403) == :http_403
    assert HttpStatus.reason(404) == :http_404
  end

  test "an unknown status never creates an atom" do
    before = :erlang.system_info(:atom_count)

    assert HttpStatus.reason(799) == :http_unexpected_status
    assert HttpStatus.reason(999) == :http_unexpected_status

    assert :erlang.system_info(:atom_count) == before
  end
end
