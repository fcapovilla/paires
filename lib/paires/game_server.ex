defmodule Paires.GameServer do
  use GenServer

  alias Paires.PubSub

  @round_time 90
  @min_players 3

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

  def ready_vote(room, player) do
    GenServer.call(get_pid(room), {:ready_vote, player})
  end

  def new_round_vote(room, player) do
    GenServer.call(get_pid(room), {:new_round_vote, player})
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
      ready_votes: %{},
      new_round_votes: %{},
      round: 0,
      images: [],
      score: %{},
      pairs: %{},
      timer: 0,
      players_per_pair: %{},
      score_per_pair: %{},
      players_per_last_image: %{},
      score_per_last_image: %{},
      round_score: %{},
    }}
  end

  @impl true
  def handle_call({:start_game}, _from, %{state: :choose_pairs} = state), do: {:reply, :ok, state}
  def handle_call({:start_game}, _from, %{round: 4} = state) do
    state = %{state |
      round: 0,
      score: %{},
    }
    {:reply, :ok, state |> start_round() |> broadcast!()}
  end
  def handle_call({:start_game}, _from, state) do
    {:reply, :ok, state |> start_round() |> broadcast!()}
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
      pairs: pairs,
    }
    {:reply, :ok, broadcast!(state)}
  end
  def handle_call({:set_pair, _player, _images}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:delete_pair, player, image}, _from, %{state: :choose_pairs} = state) do
    player_pairs = (state.pairs[player] || %{}) |> Map.drop([image])
    pairs = state.pairs |> Map.put(player, player_pairs)
    ready_votes =
      if Enum.count(player_pairs) < 5 do
        Map.drop(state.ready_votes, [player])
      else
        state.ready_votes
      end
    state = %{state |
      pairs: pairs,
      ready_votes: ready_votes,
    }
    {:reply, :ok, broadcast!(state)}
  end
  def handle_call({:delete_pair, _player, _image}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:ready_vote, player}, _from, %{state: :choose_pairs, timer: timer} = state) when timer > 0 do
    ready_votes = Map.put(state.ready_votes, player, true)
    state =
      if Enum.count(ready_votes) == Enum.count(state.players) do
        %{state | timer: 0, ready_votes: %{}}
      else
        %{state | ready_votes: ready_votes}
      end
    {:reply, :ok, broadcast!(state)}
  end
  def handle_call({:ready_vote, _player}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:new_round_vote, player}, _from, %{state: :score} = state) do
    new_round_votes = Map.put(state.new_round_votes, player, true)
    state =
      if Enum.count(new_round_votes) > Enum.count(state.players) / 2 do
        start_round(state)
      else
        %{state | new_round_votes: new_round_votes}
      end
    {:reply, :ok, broadcast!(state)}
  end
  def handle_call({:new_round_vote, _player}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:reset_vote, player}, _from, state) do
    reset_votes = Map.put(state.reset_votes, player, true)
    state =
      if Enum.count(reset_votes) > Enum.count(state.players) / 2 do
        %{state | state: :ready, reset_votes: %{}, timer: 0, round: 0, score: %{}}
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
  def handle_info(:tick, %{state: :choose_pairs} = state) do
    state =
      cond do
        state.timer > 0 ->
          Process.send_after(self(), :tick, 1000)
          %{state | timer: state.timer - 1}
        true -> end_round(state)
      end
    {:noreply, broadcast!(state)}
  end
  def handle_info(:tick, state), do: {:noreply, state}

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
    if Enum.count(players) >= @min_players do
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
      x when x < @min_players ->
        %{state | state: :waiting_for_players, players: players, reset_votes: %{}, timer: 0, round: 0, score: %{}}
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

  def end_round(state) do
    nb_players = Enum.count(state.players)
    players_per_pair =
      Enum.reduce(state.pairs, %{}, fn {player, pairs}, acc ->
        Enum.reduce(pairs, acc, fn pair, acc2 ->
          Map.put(acc2, pair, Map.get(acc2, pair, []) ++ [player])
        end)
      end)
    score_per_pair =
      Enum.map(players_per_pair, fn {pair, players} ->
        score = Enum.count(players)
        case score do
          1 -> {pair, 0}
          ^nb_players -> {pair, 0}
          _ -> {pair, score}
        end
      end)
      |> Enum.into(%{})
    last_images =
      Enum.map(state.pairs, fn {player, pairs} ->
        {player, Enum.flat_map(pairs, fn {k, v} ->
          [k, v]
        end)}
      end)
      |> Enum.map(fn {player, images} ->
           remaining = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"] -- images
           if Enum.count(remaining) == 1, do: {player, hd(remaining)}, else: nil
         end)
      |> Enum.reject(&(&1 == nil))
      |> Enum.into(%{})
    players_per_last_image =
      Enum.reduce(last_images, %{}, fn {player, image}, acc ->
        Map.put(acc, image, Map.get(acc, image, []) ++ [player])
      end)
    score_per_last_image =
      Enum.map(players_per_last_image, fn {image, players} ->
        score = Enum.count(players)
        case score do
          1 -> {image, 0}
          _ -> {image, score * 2}
        end
      end)
      |> Enum.into(%{})
    round_score =
      Enum.map(state.players, fn {player, _} ->
        score = if last_images[player], do: score_per_last_image[last_images[player]], else: 0
        score = score + Enum.reduce(state.pairs[player] || %{}, 0, fn pair, acc ->
          acc + Map.get(score_per_pair, pair, 0)
        end)
        {player, score}
      end)
      |> Enum.into(%{})
    score =
      Enum.map(state.players, fn {player, _} ->
        {player, Map.get(state.score, player, 0) + round_score[player]}
      end)
      |> Enum.into(%{})

    %{state |
      state: :score,
      players_per_pair: players_per_pair,
      score_per_pair: score_per_pair,
      players_per_last_image: players_per_last_image,
      score_per_last_image: score_per_last_image,
      round_score: round_score,
      score: score,
    }
  end

  defp start_round(state) do
    Process.send_after(self(), :tick, 1000)
    %{state |
      state: :choose_pairs,
      reset_votes: %{},
      ready_votes: %{},
      new_round_votes: %{},
      round: state.round + 1,
      images: fetch_images(),
      pairs: %{},
      timer: @round_time,
      players_per_pair: %{},
      score_per_pair: %{},
      players_per_last_image: %{},
      score_per_last_image: %{},
      round_score: %{},
    }
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