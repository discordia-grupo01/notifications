defmodule Notifications.Delivery.Sender.HttpStatus do
  @reasons %{
    300 => :http_300,
    301 => :http_301,
    302 => :http_302,
    303 => :http_303,
    304 => :http_304,
    305 => :http_305,
    307 => :http_307,
    308 => :http_308,
    400 => :http_400,
    401 => :http_401,
    402 => :http_402,
    403 => :http_403,
    404 => :http_404,
    405 => :http_405,
    406 => :http_406,
    407 => :http_407,
    408 => :http_408,
    409 => :http_409,
    410 => :http_410,
    411 => :http_411,
    412 => :http_412,
    413 => :http_413,
    414 => :http_414,
    415 => :http_415,
    416 => :http_416,
    417 => :http_417,
    421 => :http_421,
    422 => :http_422,
    423 => :http_423,
    424 => :http_424,
    425 => :http_425,
    426 => :http_426,
    428 => :http_428,
    431 => :http_431,
    451 => :http_451
  }

  @spec reason(integer()) :: atom()
  def reason(status), do: Map.get(@reasons, status, :http_unexpected_status)
end
