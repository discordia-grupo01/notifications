defmodule NotificationsWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias NotificationsWeb.ErrorJSON

  @code_regex ~r/^[A-Z][A-Z0-9_]*$/

  @expected %{
    "400.json" => "INVALID_BODY",
    "401.json" => "UNAUTHORIZED",
    "403.json" => "FORBIDDEN",
    "404.json" => "NOT_FOUND",
    "405.json" => "METHOD_NOT_ALLOWED",
    "406.json" => "NOT_ACCEPTABLE",
    "413.json" => "PAYLOAD_TOO_LARGE",
    "415.json" => "UNSUPPORTED_MEDIA_TYPE",
    "500.json" => "INTERNAL_ERROR",
    "502.json" => "INTERNAL_ERROR",
    "503.json" => "INTERNAL_ERROR",
    "garbage.json" => "INTERNAL_ERROR"
  }

  for {template, code} <- @expected do
    test "renders #{template} as #{code} with the full envelope" do
      assert %{error: %{code: code, message: message, details: details}} =
               ErrorJSON.render(unquote(template), %{})

      assert code == unquote(code)
      assert code =~ @code_regex
      assert is_binary(message) and message != ""
      assert details == %{}
    end
  end

  test "never exposes a numeric code" do
    refute ErrorJSON.render("404.json", %{}).error.code =~ ~r/^\d+$/
  end
end
