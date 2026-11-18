defmodule NotificationsWeb.ErrorJSON do
  alias NotificationsWeb.ApiError

  @reasons %{
    400 => :invalid_payload,
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    405 => :method_not_allowed,
    406 => :not_acceptable,
    413 => :payload_too_large,
    415 => :unsupported_media_type
  }

  def render(template, _assigns) do
    reason =
      case Integer.parse(template) do
        {status, _rest} -> Map.get(@reasons, status, :internal_error)
        :error -> :internal_error
      end

    ApiError.payload(reason)
  end
end
