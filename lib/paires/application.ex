defmodule Paires.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      PairesWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Paires.PubSub},
      PairesWeb.Presence,
      # Start the Endpoint (http/https)
      PairesWeb.Endpoint,
      {Registry, keys: :unique, name: Paires.RoomRegistry},
      Paires.GameSupervisor
      # Start a worker by calling: Paires.Worker.start_link(arg)
      # {Paires.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Paires.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    PairesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
