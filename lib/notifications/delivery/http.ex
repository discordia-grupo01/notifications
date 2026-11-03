defmodule Notifications.Delivery.Http do
  @type headers :: [{String.t(), String.t()}]
  @type response :: %{status: non_neg_integer(), headers: headers(), body: binary()}

  @callback post(url :: String.t(), headers(), body :: binary(), timeout_ms :: pos_integer()) ::
              {:ok, response()} | {:error, :timeout | :connect_failed | :request_failed}

  @spec post(String.t(), headers(), binary(), pos_integer()) ::
          {:ok, response()} | {:error, :timeout | :connect_failed | :request_failed}
  def post(url, headers, body, timeout_ms), do: impl().post(url, headers, body, timeout_ms)

  @spec header(response(), String.t()) :: String.t() | nil
  def header(%{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  @spec retry_after_ms(response()) :: non_neg_integer() | nil
  def retry_after_ms(response) do
    with value when is_binary(value) <- header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(value) do
      seconds * 1_000
    else
      _missing -> nil
    end
  end

  defp impl,
    do: Application.get_env(:notifications, :delivery_http, Notifications.Delivery.Http.Httpc)
end
