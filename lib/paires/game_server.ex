defmodule Paires.GameServer do
  use GenServer

  alias Paires.PubSub

  # Client Code

  def start_link(room) do
    GenServer.start(__MODULE__, room, name: {:via, Registry, {Paires.RoomRegistry, room}})
  end

  def get_pid(room) do
    GenServer.whereis({:via, Registry, {Paires.RoomRegistry, room}})
  end

  def start_game(room) do
    GenServer.call(get_pid(room), {:start_game})
  end

  def reset_vote(room, player) do
    GenServer.call(get_pid(room), {:reset_vote, player})
  end

  def set_pair(room, player, pair) do
    GenServer.call(get_pid(room), {:set_pair, player, pair})
  end

  def delete_pair(room, player, image) do
    GenServer.call(get_pid(room), {:delete_pair, player, image})
  end

  def get_state(room) do
    GenServer.call(get_pid(room), {:get_state})
  end

  # GenServer code

  @impl true
  def init(room) do
    Phoenix.PubSub.subscribe(PubSub, "paires:presence:" <> room)
    {:ok, %{
      room: room,
      state: :waiting_for_players,
      players: %{},
      reset_votes: %{},
      round: 0,
      images: [],
      score: %{},
      pairs: %{},
    }}
  end

  @impl true
  def handle_call({:start_game}, _from, %{state: :choose_pairs} = state), do: {:reply, :ok, state}
  def handle_call({:start_game}, _from, %{round: 4} = state) do
    state = %{state |
      state: :choose_pairs,
      round: 1,
      images: fetch_images(),
      pairs: %{},
    }
    {:reply, :ok, broadcast!(state)}
  end
  def handle_call({:start_game}, _from, state) do
    state = %{state |
      state: :choose_pairs,
      round: state.round + 1,
      images: fetch_images(),
      pairs: %{},
    }
    {:reply, :ok, broadcast!(state)}
  end

  @impl true
  def handle_call({:set_pair, player, {image1, image2}}, _from, %{state: :choose_pairs} = state) do
    player_pairs =
      if image1 < image2 do
        (state.pairs[player] || %{}) |> Map.put(image1, image2)
      else
        (state.pairs[player] || %{}) |> Map.put(image2, image1)
      end
    pairs = state.pairs |> Map.put(player, player_pairs)
    state = %{state |
      pairs: pairs
    }
    {:reply, :ok, broadcast!(state)}
  end

  @impl true
  def handle_call({:delete_pair, player, image}, _from, %{state: :choose_pairs} = state) do
    player_pairs = (state.pairs[player] || %{}) |> Map.drop([image])
    pairs = state.pairs |> Map.put(player, player_pairs)
    state = %{state |
      pairs: pairs
    }
    {:reply, :ok, broadcast!(state)}
  end

  @impl true
  def handle_call({:timeout}, _from, %{state: :choose_pairs} = state) do
    state = %{state |
      state: :choose_pairs,
    }
    {:reply, :ok, broadcast!(state)}
  end

  @impl true
  def handle_call({:reset_vote, player}, _from, state) do
    reset_votes = Map.put(state.reset_votes, player, true)
    state =
      if Enum.count(reset_votes) > Enum.count(state.players) / 2 do
        %{state | state: :ready, reset_votes: %{}}
      else
        %{state | reset_votes: reset_votes}
      end
    {:reply, :ok, broadcast!(state)}
  end

  @impl true
  def handle_call({:get_state}, _from, state) do
    {:reply, get_public_state(state), state}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, state) do
    state =
      state
      |> handle_joins(diff.joins)
      |> handle_leaves(diff.leaves)

    if Enum.count(state.players) > 0 do
      {:noreply, broadcast!(state)}
    else
      {:stop, :normal, state}
    end
  end

  defp handle_joins(state, players) do
    joins = Enum.map(players, fn {id, %{metas: [meta|_]}} -> {id, meta} end) |> Map.new()
    players = Map.merge(state.players, joins)
    if Enum.count(players) >= 1 do
      if state.state == :waiting_for_players do
        %{state | state: :ready, players: players}
      else
        %{state | players: players}
      end
    else
      %{state | state: :waiting_for_players, players: players}
    end
  end

  defp handle_leaves(state, players) do
    leaves = Enum.map(players, fn {id, %{metas: [meta|_]}} -> {id, meta} end) |> Map.new()
    players = Map.drop(state.players, Map.keys(leaves))
    case Enum.count(players) do
      x when x < 1 ->
        %{state | state: :waiting_for_players, players: players}
      _ ->
        %{state | players: players}
    end
  end

  defp fetch_images() do
    themes = [
      "nature",
      "animal",
      "object",
      "building",
      "toy",
      "technology",
      "cartoon",
      "people",
      "business",
      "food",
      "drink",
      "fashion",
      "health",
      "interior",
      "travel",
      "texture",
      "sport",
      "art",
      "history",
    ]
    Enum.map(Enum.take_random(themes, 11), fn(theme) ->
      {:ok, response} = Paires.HttpClient.get("https://source.unsplash.com/180x180/?#{theme}")
      response.headers |> Enum.into(%{}) |> Map.get("location")
    end)
  end

  defp get_public_state(state) do
    Map.drop(state, [])
  end

  defp broadcast!(state) do
    Phoenix.PubSub.broadcast!(PubSub, "paires:room:" <> state.room, %{
      event: :state_changed, payload: get_public_state(state)
    })
    state
  end
end