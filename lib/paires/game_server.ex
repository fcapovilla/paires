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
    GenServer.call(get_pid(room), {:start_game}, 30_000)
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

  def next_score_vote(room, player) do
    GenServer.call(get_pid(room), {:next_score_vote, player})
  end

  def new_round_vote(room, player) do
    GenServer.call(get_pid(room), {:new_round_vote, player}, 30_000)
  end

  def get_state(room) do
    GenServer.call(get_pid(room), {:get_state})
  end

  # GenServer code

  @impl true
  def init(room) do
    Phoenix.PubSub.subscribe(PubSub, "paires:presence:" <> room)

    {:ok,
     %{
       room: room,
       state: :waiting_for_players,
       players: %{},
       player_order: [],
       reset_votes: %{},
       ready_votes: %{},
       new_round_votes: %{},
       next_score_votes: %{},
       round: 0,
       images: [],
       score: %{},
       pairs: %{},
       timer: 0,
       pair_scores: %{},
       last_image_scores: %{},
       round_score: %{}
     }}
  end

  @impl true
  def handle_call({:start_game}, _from, %{state: :choose_pairs} = state), do: {:reply, :ok, state}

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
    state = %{state | pairs: pairs}
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

    state = %{state | pairs: pairs, ready_votes: ready_votes}
    {:reply, :ok, broadcast!(state)}
  end

  def handle_call({:delete_pair, _player, _image}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:ready_vote, player}, _from, %{state: :choose_pairs, timer: timer} = state)
      when timer > 0 do
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
  def handle_call({:next_score_vote, player}, _from, %{state: :score} = state) do
    next_score_votes = Map.put(state.next_score_votes, player, true)

    state =
      if Enum.count(next_score_votes) > Enum.count(state.players) / 2 do
        pair_scores = Enum.drop(state.pair_scores, 1)

        if Enum.count(pair_scores) > 0 do
          %{state | pair_scores: pair_scores, next_score_votes: %{}}
        else
          score =
            state.player_order
            |> Enum.map(fn player ->
              {player, (state.score[player] || 0) + (state.round_score[player] || 0)}
            end)
            |> Enum.into(%{})

          %{state | pair_scores: pair_scores, next_score_votes: %{}, score: score}
        end
      else
        %{state | next_score_votes: next_score_votes}
      end

    {:reply, :ok, broadcast!(state)}
  end

  def handle_call({:next_score_vote, _player}, _from, state), do: {:reply, :ok, state}

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
      if state.timer > 0 do
        Process.send_after(self(), :tick, 1000)
        %{state | timer: state.timer - 1}
      else
        end_round(state)
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
    joins = players |> Enum.map(fn {id, %{metas: [meta | _]}} -> {id, meta} end) |> Map.new()
    players = Map.merge(state.players, joins)
    player_order = Enum.uniq(state.player_order ++ Map.keys(joins))

    if Enum.count(players) >= @min_players do
      if state.state == :waiting_for_players do
        %{state | state: :ready, players: players, player_order: player_order}
      else
        %{state | players: players, player_order: player_order}
      end
    else
      %{state | state: :waiting_for_players, players: players, player_order: player_order}
    end
  end

  defp handle_leaves(state, players) do
    leaves = players |> Enum.map(fn {id, %{metas: [meta | _]}} -> {id, meta} end) |> Map.new()
    players = Map.drop(state.players, Map.keys(leaves))

    if Enum.count(players) < @min_players do
      %{
        state
        | state: :waiting_for_players,
          players: players,
          reset_votes: %{},
          timer: 0,
          round: 0,
          score: %{}
      }
    else
      %{state | players: players}
    end
  end

  defp fetch_images(tries \\ 5) when tries > 0 do
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
      "culinary",
      "music",
      "drink",
      "fashion",
      "health",
      "interior",
      "travel",
      "sport",
      "art",
      "history"
    ]

    images =
      themes
      |> Enum.take_random(15)
      |> Task.async_stream(&fetch_image/1, max_concurrency: 5, timeout: 30_000)
      |> Enum.to_list()
      |> Enum.map(fn {_, value} -> value end)
      |> Enum.uniq()
      |> Enum.take(11)

    if Enum.count(images) != 11 do
      fetch_images(tries - 1)
    else
      images
    end
  end

  defp fetch_image(theme) do
    {:ok, response} =
      Paires.HttpClient.get("https://source.unsplash.com/random/400x400/?#{theme}")

    url = response.headers |> Enum.into(%{}) |> Map.get("location")

    if url =~ ~r/source-404/ do
      {:ok, response} = Paires.HttpClient.get("https://source.unsplash.com/random/400x400/")
      response.headers |> Enum.into(%{}) |> Map.get("location")
    else
      url
    end
  end

  def end_round(state) do
    players_per_pair =
      Enum.reduce(state.pairs, %{}, fn {player, pairs}, acc ->
        Enum.reduce(pairs, acc, fn pair, acc2 ->
          Map.put(acc2, pair, Map.get(acc2, pair, []) ++ [player])
        end)
      end)

    # Pairs with a single player give 0 points. Pairs with x players give x points.
    score_per_pair =
      players_per_pair
      |> Enum.map(fn {pair, players} ->
        case Enum.count(players) do
          1 -> {pair, 0}
          count -> {pair, count}
        end
      end)
      |> Enum.into(%{})

    pair_scores =
      state.player_order
      |> Enum.map_reduce([], fn player, acc ->
        # Exclude pairs that were already shown by previous players
        pairs = Enum.to_list(state.pairs[player] || %{}) -- acc

        score =
          Enum.map(pairs, fn pair ->
            %{
              pair: pair,
              players: players_per_pair[pair],
              score: score_per_pair[pair]
            }
          end)

        {{player, score}, acc ++ pairs}
      end)
      |> elem(0)
      |> Enum.filter(&(elem(&1, 1) != []))

    last_images =
      state.pairs
      |> Enum.map(fn {player, pairs} ->
        images = Enum.flat_map(pairs, &Tuple.to_list/1)
        remaining = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"] -- images
        if Enum.count(remaining) == 1, do: {player, hd(remaining)}, else: nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.into(%{})

    players_per_last_image =
      Enum.reduce(last_images, %{}, fn {player, image}, acc ->
        Map.put(acc, image, Map.get(acc, image, []) ++ [player])
      end)

    # Images with a single player give 0 points. Images with x players give x*2 points.
    score_per_last_image =
      players_per_last_image
      |> Enum.map(fn {image, players} ->
        case Enum.count(players) do
          1 -> {image, 0}
          count -> {image, count * 2}
        end
      end)
      |> Enum.into(%{})

    last_image_scores =
      Enum.map(players_per_last_image, fn {image, players} ->
        %{image: image, players: players, score: score_per_last_image[image]}
      end)

    round_score =
      state.players
      |> Enum.map(fn {player, _} ->
        score = if last_images[player], do: score_per_last_image[last_images[player]], else: 0

        score =
          score +
            Enum.reduce(state.pairs[player] || %{}, 0, fn pair, acc ->
              acc + (score_per_pair[pair] || 0)
            end)

        {player, score}
      end)
      |> Enum.into(%{})

    %{
      state
      | state: :score,
        pair_scores: pair_scores,
        last_image_scores: last_image_scores,
        next_score_votes: %{},
        round_score: round_score
    }
  end

  defp start_round(%{round: 4} = state), do: start_round(%{state | round: 0, score: %{}})

  defp start_round(state) do
    {_, player_order} = get_next_player(state.players, state.player_order)
    Process.send_after(self(), :tick, 1000)

    %{
      state
      | state: :choose_pairs,
        player_order: player_order,
        reset_votes: %{},
        ready_votes: %{},
        new_round_votes: %{},
        next_score_votes: %{},
        round: state.round + 1,
        images: fetch_images(),
        pairs: %{},
        timer: @round_time,
        pair_scores: %{},
        last_image_scores: %{},
        round_score: %{}
    }
  end

  defp get_next_player(players, player_order, limit \\ 20)

  defp get_next_player(players, _player_order, 0) do
    # Could not find a player in time. Reset player order.
    player_order = Map.keys(players)
    {List.last(player_order), player_order}
  end

  defp get_next_player(players, player_order, limit) do
    player = List.first(player_order)
    player_order = player_order |> List.delete_at(0) |> List.insert_at(-1, player)

    if players[player] do
      {player, player_order}
    else
      get_next_player(players, player_order, limit - 1)
    end
  end

  defp get_public_state(state) do
    Map.drop(state, [:player_order])
  end

  defp broadcast!(state) do
    Phoenix.PubSub.broadcast!(PubSub, "paires:room:" <> state.room, %{
      event: :state_changed,
      payload: get_public_state(state)
    })

    state
  end
end
