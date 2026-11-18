defmodule NotificationsWeb.ApiErrorTest do
  use ExUnit.Case, async: true

  alias NotificationsWeb.ApiError

  @code_regex ~r/^[A-Z][A-Z0-9_]*$/

  @reasons [
    :forbidden,
    :channel_not_found,
    :server_not_found,
    :invalid_payload,
    :unauthorized,
    :not_found,
    :method_not_allowed,
    :not_acceptable,
    :payload_too_large,
    :unsupported_media_type,
    :ticket_unavailable,
    :unread_unavailable,
    :settings_unavailable,
    :history_unavailable,
    :device_limit,
    :push_unavailable,
    :push_not_configured,
    :internal_error
  ]

  for reason <- @reasons do
    test "payload(#{inspect(reason)}) has the full envelope" do
      assert %{error: %{code: code, message: message, details: details}} =
               ApiError.payload(unquote(reason))

      assert code =~ @code_regex
      assert is_binary(message) and message != ""
      assert details == %{}
    end
  end

  test "the envelope has a single top-level key" do
    assert [:error] = ApiError.payload(:forbidden) |> Map.keys()
  end

  test "details is passed through as an object" do
    assert %{error: %{details: %{"field" => "level"}}} =
             ApiError.payload(:invalid_payload, %{"field" => "level"})
  end

  test "invalid_payload maps to INVALID_BODY / 400" do
    assert %{error: %{code: "INVALID_BODY"}} = ApiError.payload(:invalid_payload)
    assert ApiError.http_status(:invalid_payload) == 400
  end

  test "unknown reasons fall back to INTERNAL_ERROR / 500 without crashing" do
    for reason <- [:something_new, %{__struct__: Mongo.Error, message: "boom"}, "text", nil] do
      assert %{error: %{code: "INTERNAL_ERROR", message: message, details: %{}}} =
               ApiError.payload(reason)

      assert message != ""
      refute message =~ "boom"
      assert ApiError.http_status(reason) == 500
    end
  end
end
