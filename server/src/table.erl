-module(table).

-include("tarabish_types.hrl").
-include("client.hrl").

-behaviour(gen_server).

-export([start/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
   terminate/2, code_change/3]).

-export([chat/3, join/3, part/1, sit/3, stand/1,
    start_game/1, call_trump/2, play_card/2, play_bella/1,
    call_run/1, show_run/1]).

%% From game
-export([broadcast/2, deal3/3]).

-record(person, {name, client, seat}).
-record(state, {id, seats, observers, members, game}).

% Public:
start(Id) ->
  gen_server:start(?MODULE, [Id], []).

%% TODO: check if table is still alive
chat(Table, From, Message) ->
  Event = [ {type, <<"chat">>},
    {name, From}, {message, Message}],
  broadcast(Table, Event).

join(Table, ClientName, Client) ->
  gen_server:call(Table, {join, ClientName, Client}).

part(Table) ->
  gen_server:call(Table, {part, self()}).

sit(Table, ClientName, Seat) ->
  gen_server:call(Table, {sit, ClientName, self(), Seat}).

stand(Table) ->
  gen_server:call(Table, {stand, self()}).

start_game(Table) ->
  gen_server:call(Table, {start_game, self()}).

call_trump(Table, Suit) ->
  gen_server:call(Table, {call_trump, self(), Suit}).

play_card(Table, Card) ->
  DCard = protocol:deseralize_card(Card),
  gen_server:call(Table, {play_card, self(), DCard}).

play_bella(Table) ->
  gen_server:call(Table, {play_bella, self()}).

call_run(Table) ->
  gen_server:call(Table, {call_run, self()}).

show_run(Table) ->
  gen_server:call(Table, {show_run, self()}).

% From Game:
broadcast(Table, Event) ->
  gen_server:cast(Table, {broadcast, Event}).

deal3(Table, Dealer, Cards) ->
  gen_server:cast(Table, {deal3, Dealer, Cards}).

% gen_server:

init([Id]) ->
  process_flag(trap_exit, true),
  Seats = {empty, empty, empty, empty},
  State = #state{id=Id, seats=Seats, observers=[], members=orddict:new(),
                 game=none},
  update_server(State),
  {ok, State}.

handle_call({join, ClientName, Client}, _From, State) ->
  case orddict:find(ClientName, State#state.members) of
    {ok, _Person} ->
      {reply, {error, already_joined}, State};
    error ->
      Event = #event{type=?tarabish_EventType_JOIN,
                     name=ClientName},
      send_event_all(Event, State),
      Person = #person{name=ClientName, client=Client, seat=none},
      NewMembers = orddict:store(Client, Person, State#state.members),
      Observers = [ClientName|State#state.observers],
      NewState = State#state{members=NewMembers, observers=Observers},
      update_server(NewState),
      send_event_one(#event{type=?tarabish_EventType_TABLEVIEW,
                            table_view=make_table_view(NewState)}, NewState, Client),
      {reply, ok, NewState}
  end;

handle_call({part, Client}, _From, State) ->
  case orddict:find(Client, State#state.members) of
    % Not called as you can only sit/part so far.
%    {ok, #person{seat=none} = _Person} ->
%      send_event_all(Event, State),
%      NewMembers = orddict:erase(ClientName, State#state.members),
%      NewObservers = lists:delete(ClientName, State#state.observers),
%      NewState = State#state{members=NewMembers, observers=NewObservers},
%      update_server(NewState),
%      {reply, ok, NewState};
    {ok, #person{name=ClientName, seat=SeatNum} = _Person} ->
      % No stand yet, as no observers for client.
%      send_event_all(StandEvent#event{seat=SeatNum}, State),
      Event = [ {type, <<"part">>},
                {name, ClientName},
                {seat, SeatNum}],
      send_event_all(Event, State),
      cancel_game(State),

      NewMembers = orddict:erase(Client, State#state.members),
      NewSeats = setelement(SeatNum + 1, State#state.seats, empty),
      NewState = State#state{members=NewMembers, seats=NewSeats, game=none},
      update_server(NewState),
      {reply, ok, NewState};
    error ->
      {reply, {error, no_at_table}, State}
  end;

handle_call({sit, ClientName, Client, SeatNum}, _From, State)
  when SeatNum >= 0, SeatNum < 4 ->
  Seat = get_seat(State, SeatNum),
  if Seat == empty ->
    ClientRec = #client{name=ClientName, pid=Client},
    NewSeats = setelement(SeatNum + 1, State#state.seats, ClientRec),
    Event = [ {type, <<"sit">>},
              {name, ClientName},
              {seat, SeatNum}],
    case orddict:find(Client, State#state.members) of
      {ok, #person{seat=none} = Person} ->
        send_event_all(Event, State),
        NewPerson = Person#person{seat=SeatNum},
        NewMembers = orddict:store(Client, NewPerson, State#state.members),
        NewObservers = lists:delete(ClientName, State#state.observers),
        NewState = State#state{members=NewMembers, seats=NewSeats, observers=NewObservers},
        update_server(NewState),
        {reply, ok, NewState};
      {ok, _Person} ->
          {reply, {error, already_seated}, State};
      error -> % Not at table, join
        send_event_all(Event, State),
        NewPerson = #person{name=ClientName, client=Client, seat=SeatNum},
        NewMembers = orddict:store(Client, NewPerson, State#state.members),
        NewState = State#state{members=NewMembers, seats=NewSeats},
        update_server(NewState),

        % Send a new client a table view
        % TODO: send table view
        EventT = [ {type, <<"table_view_sit">>},
          {table_view, make_table_view(NewState)},
          {seat, SeatNum}],
        send_event_one(EventT, State, Client),
        {reply, ok, NewState}
    end;
  true ->
    {reply, {error, seat_taken}, State}
  end;

handle_call({sit, _ClientName, _Client, _SeatNum}, _From, State) ->
    {reply, {error, invalid_seat}, State};

handle_call({start_game, Client}, _From, #state{game=none} = State) ->
  case orddict:find(Client, State#state.members) of
    {ok, #person{seat=none}} ->
      {reply, {error, not_authorized}, State};
    {ok, _Person} ->
      case is_full(State#state.seats) of
        true ->
          Event = [{type, <<"new_game">>}],
          send_event_all(Event, State),
          {ok, Game} = game:start_link(self()),
          {reply, ok, State#state{game=Game}};
        false ->
          {reply, {error, need_full_table}, State}
      end;
    error ->
      {reply, {error, not_at_table}, State}
  end;

handle_call({stand, Client}, _From, State) ->
 case orddict:find(Client, State#state.members) of
    {ok, #person{seat=none} = _Person} ->
      {reply, {error, not_seated}, State};
    {ok, #person{name=ClientName, seat=SeatNum} = Person} ->
      Event = #event{type=?tarabish_EventType_STAND,
                 name=ClientName},
      send_event_all(Event#event{seat=SeatNum}, State),
      cancel_game(State),
      NewPerson = Person#person{seat=none},
      NewSeats = setelement(SeatNum + 1, State#state.seats, empty),
      NewMembers = orddict:store(Client, NewPerson, State#state.members),
      NewObservers = [ClientName|State#state.observers],

      NewState = State#state{members=NewMembers, seats=NewSeats,
        observers=NewObservers, game=none},
      update_server(NewState),
      {reply, ok, NewState};
    error ->
      {reply, {error, not_at_table}, State}
  end;

handle_call({start_game, _ClientName}, _From, State) ->
  {reply, {error, already_started}, State};

handle_call({call_trump, _ClientName, _Suit}, _From, #state{game=none} = State) ->
  {reply, {error, no_game}, State};

handle_call({call_trump, Client, Suit}, _From, State) ->
  case orddict:find(Client, State#state.members) of
      {ok, #person{seat=none}} ->
        {reply, {error, not_authorized}, State};
      {ok, Person} ->
        Reply = game:call_trump(State#state.game, Person#person.seat, Suit),
        {reply, Reply, State};
      error ->
        {reply, {error, not_at_table}, State}
    end;

handle_call({play_card, _ClientName, _Card}, _From, #state{game=none} = State) ->
  {reply, {error, no_game}, State};

% TODO: not_authorized isn't really needed here, as it shoudl be checked in the game
handle_call({play_card, Client, Card}, _From, State) ->
  case orddict:find(Client, State#state.members) of
      {ok, #person{seat=none}} ->
        {reply, {error, not_authorized}, State};
      {ok, Person} ->
        Reply = game:play_card(State#state.game, Person#person.seat, Card),
        {reply, Reply, State};
      error ->
        {reply, {error, not_at_table}, State}
    end;

handle_call({play_bella, _ClientName}, _From, #state{game=none} = State) ->
  {reply, {error, no_game}, State};

handle_call({play_bella, Client}, _From, State) ->
  case orddict:find(Client, State#state.members) of
    {ok, #person{seat=none}} ->
      {reply, {error, not_authorized}, State};
    {ok, Person} ->
      Reply = game:play_bella(State#state.game, Person#person.seat),
      {reply, Reply, State};
    error ->
      {reply, {error, not_at_table}, State}
  end;

handle_call({call_run, _ClientName}, _From, #state{game=none} = State) ->
  {reply, {error, no_game}, State};

handle_call({call_run, Client}, _From, State) ->
  case orddict:find(Client, State#state.members) of
    {ok, #person{seat=none}} ->
      {reply, {error, not_authorized}, State};
    {ok, Person} ->
      Reply = game:call_run(State#state.game, Person#person.seat),
      {reply, Reply, State};
    error ->
      {reply, {error, not_at_table}, State}
  end;

handle_call({show_run, _ClientName}, _From, #state{game=none} = State) ->
  {reply, {error, no_game}, State};

handle_call({show_run, Client}, _From, State) ->
  case orddict:find(Client, State#state.members) of
    {ok, #person{seat=none}} ->
      {reply, {error, not_authorized}, State};
    {ok, Person} ->
      Reply = game:show_run(State#state.game, Person#person.seat),
      {reply, Reply, State};
    error ->
      {reply, {error, not_at_table}, State}
  end;

handle_call(Request, _From, State) ->
  io:format("~w received unknown call ~p~n",
    [?MODULE, Request]),
  {stop, "Bad Call", State}.

handle_cast({broadcast,
    #event{type=?tarabish_EventType_GAME_DONE} = Event}, State) ->
      send_event_all(Event, State),
      {noreply, State#state{game=none}};

handle_cast({broadcast, Event}, State) ->
  send_event_all(Event, State),
  {noreply, State};

handle_cast({deal3, Dealer, Cards}, State) ->
  send_cards(State#state.id, Dealer, Cards, State#state.members),
  {noreply, State};

handle_cast(Msg, State) ->
  io:format("~w received unknown cast ~p~n",
    [?MODULE, Msg]),
  {stop, "Bad Cast", State}.

% Game sends a done message on normal exits
handle_info({'EXIT', Game, normal}, #state{game=Game} = State) ->
  {noreply, State#state{game=none}};

handle_info({'EXIT', Game, _Reason}, #state{game=Game} = State) ->
  cancel_game(Game),
  {noreply, State#state{game=none}};

% Old games are still linked, but we don't care when they die.
% If we later monitor other processes this will have to change.
handle_info({'EXIT', _OldGame, normal}, State) ->
  {noreply, State};

handle_info(Info, State) ->
  io:format("~w recieved unknown info ~p~n",
    [?MODULE, Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% private:
cancel_game(#state{game=none}) ->
  ok;

cancel_game(#state{game=Game} = State) ->
  Event = [{type, <<"game_cancel">>}],
  game:stop(Game),
  send_event_all(Event, State).

send_event_all(Event, State) ->
  send_event(State#state.id, Event, State#state.members).

% TODO: why does one use State id, and the other passed in the Id.
send_event_one(Event, State, Client) ->
  TableEvent = [{tableId, State#state.id}] ++ Event,
  client:recv_event(Client, TableEvent).

send_event(TableId, Event, MemberDict) ->
  {_Ids, Members} = lists:unzip(orddict:to_list(MemberDict)),
  TableEvent = [{tableId, TableId}] ++ Event,
  lists:map(fun(Person) -> client:recv_event(Person#person.client, TableEvent) end,
            Members).

send_cards1(_Event, _Cards, []) ->
  ok;

send_cards1(Event, Cards, [#person{} = Person|Rest])
    when Person#person.seat == none ->
  client:recv_event(Person#person.client, Event),
  send_cards1(Event, Cards, Rest);

send_cards1(Event, Cards, [#person{} = Person|Rest]) ->
  Event1 = Event ++ [{dealt, lists:nth(Person#person.seat + 1, Cards)}],

  client:recv_event(Person#person.client, Event1),
  send_cards1(Event, Cards, Rest).

send_cards(TableId, Dealer, Cards, MembersDict) ->
  {_Ids, Persons} = lists:unzip(orddict:to_list(MembersDict)),

  SerCards = protocol:seralize_hands(Cards),

  Event = [{type, <<"deal">>}, {tableId, TableId}, {dealer, Dealer}],
  send_cards1(Event, SerCards, Persons).

% Passes a list, but returns a tuple.
get_seat(State, SeatNum) ->
  element(SeatNum + 1, State#state.seats).

update_server(State) ->
  View = make_table_view(State),
  tarabish_server:update_table_image(State#state.id, View).

make_table_view(State) ->
  Seats = erlang:tuple_to_list(State#state.seats),
  ViewSeats = make_seats_views(Seats),
  [{tableId, State#state.id},
   {seats, ViewSeats},
   {observers, State#state.observers}].

make_seats_views(Seats) ->
  make_seats_views(Seats, [], 0).

make_seats_views([], Views, _Count) ->
  lists:reverse(Views);

make_seats_views([Seat|Rest], Views, Count) ->
  SeatView = make_one_seat_view(Seat, Count),
  make_seats_views(Rest, [SeatView|Views], Count + 1).

% Seat name to empty string for UI
make_one_seat_view(empty, Count) ->
  [{isOpen, true}, {name, <<"">>}, {num, Count}];

make_one_seat_view(Seat, Count) ->
  [{isOpen, false}, {name, Seat#client.name}, {num, Count}].

is_full(Seats) when is_tuple(Seats) ->
  is_full(tuple_to_list(Seats));

is_full([]) ->
  true;

is_full([empty|_Rest]) ->
  false;

is_full([_Seat|Rest]) ->
  is_full(Rest).
