defmodule PairesWeb.GameLive do
  use PairesWeb, :live_view

  alias PairesWeb.Presence
  alias Paires.PubSub

  @impl true
  def mount(%{"room" => room}, %{"name" => name, "player_id" => player_id}, socket) do
    room = room |> String.trim() |> String.slice(0..50)
    if connected?(socket) do
      {:ok, _} = Presence.track(self(), "paires:presence:" <> room, player_id, %{
        name: name,
      })

      Phoenix.PubSub.subscribe(PubSub, "paires:room:" <> room)
    end

    if Paires.GameServer.get_pid(room) do
      {
        :ok,
        socket
        |> assign(:current_user, player_id)
        |> assign(:users, %{})
        |> assign(:selection, nil)
        |> assign(:game, Paires.GameServer.get_state(room))
      }
    else
      {:ok, socket |> redirect(to: Routes.login_path(socket, :index, room: room))}
    end
  end
  def mount(%{"room" => room}, _session, socket) do
    room = room |> String.trim() |> String.slice(0..50)
    {:ok, socket |> redirect(to: Routes.login_path(socket, :index, room: room))}
  end

  @impl true
  def handle_info(%{event: :state_changed, payload: state}, socket) do
    {
      :noreply,
      if socket.assigns.game.state != state.state do
        socket |> clear_flash() |> assign(:game, state)
      else
        socket |> assign(:game, state)
      end
    }
  end

  @impl true
  def handle_event("start_game", _value, socket) do
    Paires.GameServer.start_game(socket.assigns.game.room)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_vote", _value, socket) do
    Paires.GameServer.reset_vote(socket.assigns.game.room, socket.assigns.current_user)
    {:noreply, socket}
  end

  @impl true
  def handle_event("ready_vote", _value, socket) do
    Paires.GameServer.ready_vote(socket.assigns.game.room, socket.assigns.current_user)
    {:noreply, socket}
  end

  @impl true
  def handle_event("new_round_vote", _value, socket) do
    Paires.GameServer.new_round_vote(socket.assigns.game.room, socket.assigns.current_user)
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_image", %{"id" => id}, socket) do
    case socket.assigns.selection do
      nil -> {:noreply, socket |> assign(:selection, id)}
      ^id -> {:noreply, socket |> assign(:selection, nil)}
      _ ->
        Paires.GameServer.set_pair(
          socket.assigns.game.room,
          socket.assigns.current_user,
          {socket.assigns.selection, id}
        )
        {:noreply, socket |> assign(:selection, nil)}
    end
  end


  @impl true
  def handle_event("delete_pair", %{"id" => id}, socket) do
    Paires.GameServer.delete_pair(socket.assigns.game.room, socket.assigns.current_user, id)
    {:noreply, socket}
  end
end
