defmodule Paires.HttpClient do
  use Tesla

  adapter Tesla.Adapter.Hackney

  plug Tesla.Middleware.Headers, [{"user-agent", "Paires"}]
  plug Tesla.Middleware.Timeout, timeout: 30_000
end
