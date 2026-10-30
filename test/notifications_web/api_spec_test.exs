defmodule NotificationsWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  test "spec/0 builds a resolvable OpenAPI document for every route" do
    spec = NotificationsWeb.ApiSpec.spec()

    assert %OpenApiSpex.OpenApi{} = spec
    assert Map.has_key?(spec.paths, "/health")
    assert Map.has_key?(spec.paths, "/livez")
    assert Map.has_key?(spec.paths, "/readyz")

    assert %{post: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/notifications/socket-tickets"]
  end
end
