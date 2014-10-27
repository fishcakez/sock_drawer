-module(sd_queue_statem).

-include_lib("proper/include/proper.hrl").

-export([quickcheck/0]).
-export([quickcheck/1]).

-export([start_link/2]).
-export([queue_start_link/2]).
-export([init/1]).

-export([start_sd/2]).
-export([stop_sd/1]).
-export([connect/1]).
-export([checkout/2]).
-export([checkin/1]).
-export([close/2]).
-export([check/1]).
-export([change_creators/3]).
-export([change_targeter/3]).
-export([change_manager/4]).
-export([change_max_sockets/2]).
-export([purge/1]).

-export([initial_state/0]).
-export([command/1]).
-export([next_state/3]).
-export([precondition/2]).
-export([postcondition/3]).

-record(state, {pid, id, reload=0, targeter=0, purge=0, creators,
                old_creators=0, max_sockets, old_max_sockets=0, sockets=[],
                checkouts=[]}).

quickcheck() ->
    quickcheck([]).

quickcheck(Opts) ->
    proper:quickcheck(prop_simple(), Opts).

start_link(NumCreators, MaxSockets) ->
    sock_drawer:start_link(?MODULE, {sock_drawer, NumCreators, MaxSockets}, []).

queue_start_link(MaxSockets, Id) ->
    sd_queue:start_link(Id, ?MODULE, {sd_queue, MaxSockets},
                        [{debug, [{log, 15}]}]).

init({sock_drawer, NumCreators, MaxSockets}) ->
    Shutdown = case get(manager) of
                   undefined -> 5000;
                   A -> 5000 + A
               end,
    MaxSockets2 = case get(max_sockets) of
                      undefined -> MaxSockets;
                      B -> B
                  end,
    Manager = {manager, {?MODULE, queue_start_link, [MaxSockets2]},
               permanent, Shutdown, worker, [?MODULE, sd_queue]},
    Buffer = case get(targeter) of
                 undefined -> 1000;
                 C -> 1000 + C
             end,
    Targeter = {targeter, {sd_targeter, start_link, [[{buffer, Buffer}], 1000]},
                permanent, 5000, worker, [sd_targeter]},
    Opts = [{exit_on_close, false} | socket_opts()],
    Creator = {creator,
               {sd_creator, start_link, [Opts, 100, {0,0}, {0,0}]},
               transient, 5000, worker, [sd_creator]},
    Reload = case get(reload) of
                 undefined -> 0;
                 D -> D
             end,
    Handler = {handler, {sdt_tcp_worker, start_link, [Reload, 0]},
               temporary, 5000, worker, [sdt_tcp_worker, sd_tcp_worker]},
    NumCreators2 = case get(creators) of
                       undefined -> NumCreators;
                       E -> E
                   end,
    {ok, {{{sd_tcp, accept, {{127,0,0,1}, 0}}, NumCreators2, 0, 1},
           [Manager, Targeter, Creator, Handler]}};
init({sd_queue, MaxSockets}) ->
    MaxSockets2 = case get(max_sockets) of
                      undefined -> MaxSockets;
                      N -> N
                  end,
    {ok, MaxSockets2}.

start_sd(NumCreators, MaxSockets) ->
    case start_link(NumCreators, MaxSockets) of
        {ok, Pid} ->
            Pid;
        {error, Reason} ->
            {error, Reason}
    end.



stop_sd(Pid) ->
    Trap = process_flag(trap_exit, true),
    Shutdown = {shutdown, make_ref()},
    exit(Pid, Shutdown),
    Result = receive
                 {'EXIT', Pid, Shutdown} ->
                     ok;
                 {'EXIT', Pid, Reason} ->
                     {error,  Reason}
             after
                 10000 ->
                     {error, timeout}
             end,
    process_flag(trap_exit, Trap),
    Result.

connect(Id) ->
    {ok, LSocket} = sd_agent:find(Id, socket),
    {ok, {IP, Port}} = inet:sockname(LSocket),
    case gen_tcp:connect(IP, Port, socket_opts(), 100) of
        {ok, Socket} ->
            case gen_tcp:recv(Socket, 0, 500) of
                {ok, <<"hi", Reload:32>>} ->
                    {Socket, Reload};
                {error, _Reason} = Error ->
                    gen_tcp:close(Socket),
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

checkout(Id, Sockets) ->
    case sd_manager:socket_checkout({via, sd_reg, {Id, sd_manager}}, 200) of
        {ok, Socket, Handler, CRef} ->
            Client = find_client(Socket, Sockets),
            {ok, Socket, Client, Handler, CRef};
        {error, _Reason} = Error ->
            Error
    end.

find_client(Socket, Sockets) ->
    Data = term_to_binary(make_ref()),
    case gen_tcp:send(Socket, Data) of
        ok ->
            find_client(Socket, Sockets, Data, 200);
        {error, _Reason} = Error ->
            Error
    end.

find_client(Socket, [{error, _Reason} | Sockets], Data, Timeout) ->
    find_client(Socket, Sockets, Data, Timeout);
find_client(Socket, [{Socket2, _Reload} = Client | Sockets], Data, Timeout) ->
    case gen_tcp:recv(Socket2, 0, Timeout) of
        {ok, Data} ->
            Client;
        {error, timeout} ->
            find_client(Socket, Sockets, Data, 0);
        {error, _} ->
            find_client(Socket, Sockets, Data, Timeout)
    end;
find_client(_Socket, [], _Data, _Timeout) ->
    {error, closed}.

checkin({ok, Socket, _Client, Handler, CRef}) ->
    sd_tcp_worker:checkin(Socket, Handler, CRef);
checkin({error, _}) ->
    ok.

close({error, _Reason}, _Checkouts) ->
    ok;
close({Socket, _Reload} = Client, Checkouts) ->
    _ = gen_tcp:shutdown(Socket, write),
    case lists:keyfind(Client, 3, Checkouts) of
        {ok, Server, Client, _Handler, _CRef} ->
            gen_tcp:close(Server),
            {error, closed};
        false ->
            gen_tcp:recv(Socket, 0, 200)
    end.

check({error, _Reason}) ->
    {error, closed};
check({Socket, _Reload}) ->
    case gen_tcp:recv(Socket, 0, 0) of
        {error, timeout} ->
            ok;
        {error, _Reason} = Error ->
            Error
    end.

change_creators(Pid, Reload, Creators) ->
    sys:suspend(Pid),
    sys:replace_state(Pid, fun(State) -> put(reload, Reload),
                                         put(creators, Creators),
                                         State
                           end),
    Result = sys:change_code(Pid, ?MODULE, undefined, undefined),
    sys:resume(Pid),
    Result.

change_targeter(Pid, Reload, Creators) ->
    sys:suspend(Pid),
    sys:replace_state(Pid, fun(State) -> put(reload, Reload),
                                         put(creators, Creators),
                                         put(targeter, Reload),
                                         State
                           end),
    Result = sys:change_code(Pid, ?MODULE, undefined, undefined),
    sys:resume(Pid),
    %% sync so new targeter is started. To the manager this is just a
    %% creators change.
    Result.

change_manager(Pid, Reload, Creators, MaxSockets) ->
    Trap = process_flag(trap_exit, true),
    sys:suspend(Pid),
    sys:replace_state(Pid, fun(State) -> put(reload, Reload),
                                         put(creators, Creators),
                                         put(targeter, Reload),
                                         put(manager, Reload),
                                         put(max_sockets, MaxSockets),
                                         State
                           end),
    Result = sys:change_code(Pid, ?MODULE, undefined, undefined),
    sys:resume(Pid),
    %% sync so new manager is started
    _ = supervisor:which_children(Pid),
    %% flush socket shutdowns
    flush_port_shutdown(),
    process_flag(trap_exit, Trap),
    Result.

flush_port_shutdown() ->
    receive
        {'EXIT', Port, shutdown} when is_port(Port) ->
            flush_port_shutdown()
    after
        0 ->
            ok
    end.

change_max_sockets(Id, MaxSockets) ->
    Name = {via, sd_reg, {Id, sd_manager}},
    sys:suspend(Name),
    sys:replace_state(Name,
                      fun(State) -> put(max_sockets, MaxSockets), State end),
    Result = sys:change_code(Name, ?MODULE, undefined, undefined),
    sys:resume(Name),
    Result.

purge(Pid) ->
    Trap = process_flag(trap_exit, true),
    Result = sock_drawer:purge(Pid),
    flush_port_shutdown(),
    process_flag(trap_exit, Trap),
    Result.

creators() ->
    choose(0, 3).

max_sockets() ->
    oneof([0, 1, 2, 3, infinity]).

initial_state() ->
    #state{}.

command(#state{pid=undefined}) ->
    {call, ?MODULE, start_sd, [creators(), max_sockets()]};
command(#state{pid=Pid, reload=Reload, id=Id, sockets=Sockets,
               checkouts=Checkouts}) ->
    frequency([{20, {call, ?MODULE, checkout, [Id, Sockets]}}] ++
              [{15, {call, ?MODULE, checkin, [elements(Checkouts)]}} ||
               Checkouts =/= []] ++
              [{10, {call, ?MODULE, connect, [Id]}}] ++
              [{8, {call, ?MODULE, close, [elements(Sockets), Checkouts]}} ||
               Sockets =/= []] ++
              [{7, {call, ?MODULE, change_max_sockets, [Id, max_sockets()]}},
               {5, {call, ?MODULE, change_creators,
                    [Pid, Reload+1, creators()]}},
               {3, {call, ?MODULE, change_targeter,
                    [Pid, Reload+1, creators()]}}] ++
              [{2, {call, ?MODULE, check, [elements(Sockets)]}} ||
               Sockets =/= []] ++
              [{2, {call, ?MODULE, purge, [Pid]}},
               {1, {call, ?MODULE, change_manager,
                    [Pid, Reload+1, creators(), max_sockets()]}},
               {1, {call, ?MODULE, stop_sd, [Pid]}}]).

next_state(State, V, {call, ?MODULE, start_sd, [NumCreators, MaxSockets]}) ->
    State#state{pid=V,
                id={call, sock_drawer, id, [V]},
                creators=NumCreators,
                max_sockets=MaxSockets};
next_state(_State, _V, {call, ?MODULE, stop_sd, [_]}) ->
    #state{};
next_state(#state{sockets=Sockets} = State, V, {call, ?MODULE, connect, [_]}) ->
    State#state{sockets=Sockets ++ [V]};
next_state(#state{checkouts=Checkouts} = State, V,
           {call, ?MODULE, checkout, [_, _]}) ->
    State#state{checkouts=Checkouts ++ [V]};
next_state(#state{checkouts=Checkouts} = State, _V,
           {call, ?MODULE, checkin, [Checkout]}) ->
    State#state{checkouts=Checkouts -- [Checkout]};
next_state(#state{sockets=Sockets} = State, _V,
           {call, ?MODULE, close, [SInfo, _]}) ->
    State#state{sockets=Sockets -- [SInfo]};
next_state(State, _V, {call, ?MODULE, check, [_]}) ->
    State;
next_state(#state{creators=OldCreators} = State, _V,
           {call, ?MODULE, change_creators, [_, Reload, Creators]}) ->
    State#state{reload=Reload, creators=Creators, old_creators=OldCreators};
next_state(State, _V,
           {call, ?MODULE, change_targeter, [_, Reload, Creators]}) ->
    State#state{reload=Reload, targeter=Reload,
                creators=Creators, old_creators=0};
next_state(State, _V, {call, ?MODULE, change_manager,
                       [_, Reload, Creators, MaxSockets]}) ->
    State#state{reload=Reload, targeter=Reload, purge=Reload,
                creators=Creators, old_creators=0, max_sockets=MaxSockets,
                old_max_sockets=0};
next_state(#state{reload=Purge} = State, _V, {call, ?MODULE, purge, [_]}) ->
    State#state{purge=Purge};
next_state(#state{max_sockets=OldMaxSockets,
                  old_max_sockets=OldMaxSockets2} = State, _V,
           {call, ?MODULE, change_max_sockets, [_, MaxSockets]}) ->
    State#state{max_sockets=MaxSockets,
                old_max_sockets=max(OldMaxSockets, OldMaxSockets2)}.

precondition(_,_) ->
    true.

postcondition(_State, {call, ?MODULE, start_sd, [_, _]}, Result) ->
    case Result of
        {error, _Reason} -> false;
        _Pid -> true
    end;
postcondition(_State, {call, ?MODULE, stop_sd, [_]}, Result) ->
    case Result of
        ok -> true;
        {error, _Reason} -> false
    end;
postcondition(State, {call, ?MODULE, connect, [_]}, Result) ->
    case Result of
        {error, _Reason} ->
            maybe_no_connect(State);
        _SInfo ->
            can_connect(State)
    end;
postcondition(#state{reload=Reload, purge=Purge} = State,
              {call, ?MODULE, checkout, [_, _]}, Result) ->
    case Result of
        {error, busy} ->
            maybe_busy(State);
        {error, closed} ->
            true;
        {ok, _Socket, {Socket2, Reload2}, _Handler, _CRef}
          when is_port(Socket2), Reload >= Purge, (Reload - 1) >= Reload2 ->
            maybe_ready(State);
        {ok, _Socket, _Client, _handler, _CRef} ->
            false
    end;
postcondition(#state{purge=Purge, sockets=Sockets},
              {call, ?MODULE, checkin, [Checkout]}, Result) ->
    case Checkout of
        {ok, _Socket, {_Socket2, Reload}, _Handler, _CRef}
          when Purge > Reload ->
            Result =/= ok;
        {ok, _Socket, Client, _Handler, _CRef} when Result =:= ok ->
            lists:member(Client, Sockets);
        {ok, _Socket, Client, _Handler, _CRef} when Result =/= ok ->
            not lists:member(Client, Sockets);
        {error, _} ->
            true
    end;
postcondition(_State, {call, ?MODULE, close, [_, _]}, Result) ->
    Result =/= {error, timeout};
postcondition(#state{reload=Reload, purge=Purge},
              {call, ?MODULE, check, [SInfo]}, Result) ->
    case SInfo of
        {error, _Reason} ->
            Result =:= {error, closed};
        {_Socket, Reload} ->
            Result =:= ok;
        {_Socket, Reload2} when Reload2 >= Purge ->
            true; % Can't tell if socket should still be open.
        {_Socket, Reload2} when Purge > Reload2 ->
            Result =/= ok
    end;
postcondition(_State, {call, ?MODULE, change_creators, [_, _, _]}, Result) ->
    case Result of
        ok ->
            true;
        {error, _Reason} ->
            false
    end;
postcondition(_State, {call, ?MODULE, change_targeter, [_, _, _]}, Result) ->
    case Result of
        ok ->
            true;
        {error, _Reason} ->
            false
    end;
postcondition(#state{reload=Reload} = State,
              {call, ?MODULE, change_manager, [_, _, _, _]}, Result) ->
    case Result of
        ok ->
            check_all(State#state{purge=Reload+1});
        {error, _Reason} ->
            false
    end;
postcondition(#state{reload=Purge} = State, {call, ?MODULE, purge, [_]},
              _Result) ->
    check_all(State#state{purge=Purge});
postcondition(_State, {call, ?MODULE, change_max_sockets, [_, _]}, Result) ->
    case Result of
        ok ->
            true;
        {error, _Reason} ->
            false
    end.

prop_simple() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(begin
                          {History, State, Result} = run_commands(?MODULE, Cmds),
                          cleanup(State),
                          ?WHENFAIL(begin
                                        io:format("History~n~p", [History]),
                                        io:format("State~n~p", [State]),
                                        io:format("Result~n~p", [Result])
                                    end,
                                    aggregate(command_names(Cmds), Result =:= ok))
                      end)).

cleanup(#state{pid=undefined}) ->
    ok;
cleanup(#state{pid=Pid}) ->
    _ = (catch stop_sd(Pid)),
    ok.

socket_opts() ->
    [{active, false}, binary, {packet, 4}].

maybe_busy(#state{reload=Reload, purge=Purge, sockets=Sockets,
                  checkouts=Checkouts}) ->
    MaxRealSockets = [Socket || {Socket, Reload2} = SInfo <- Sockets,
                                is_port(Socket),
                                Reload2 >= Purge,
                                Reload2 =:= Reload orelse
                                lists:keymember(SInfo, 3, Checkouts) orelse
                                Reload2 + 1 =:= Reload],
    RealCheckouts = [Socket ||
                     {ok, Socket, {Socket, Reload2}, _, _} <- Checkouts,
                     Reload2 >= Purge,
                     Reload2 =:= Reload orelse Reload2 + 1 =:= Reload],
    if
        length(MaxRealSockets) =< length(RealCheckouts) ->
            false;
        true ->
            true
    end.


maybe_ready(_) ->
    true.

can_connect(#state{reload=Reload, purge=Purge, creators=Creators,
                   old_creators=OldCreators, sockets=Sockets,
                   max_sockets=MaxSockets, old_max_sockets=OldMaxSockets,
                   checkouts=Checkouts}) ->
    MaxSockets2 = max(MaxSockets, OldMaxSockets),
    MinRealSockets = [Socket || {Socket, Reload2} = SInfo <- Sockets,
                                is_port(Socket),
                                Reload2 >= Purge,
                                (Reload2 =:= Reload orelse
                                    lists:keymember(SInfo, 3, Checkouts))],
    if
        length(MinRealSockets) >= MaxSockets2 ->
            false;
        Creators > 0 ->
            true;
        OldCreators > 0 ->
            true;
        true ->
            false
    end.

maybe_no_connect(#state{reload=Reload, purge=Purge, creators=Creators,
                        sockets=Sockets, max_sockets=MaxSockets,
                        checkouts=Checkouts}) ->
    MaxRealSockets = [Socket || {Socket, Reload2} = SInfo <- Sockets,
                                is_port(Socket),
                                Reload2 >= Purge,
                                Reload2 =:= Reload orelse
                                lists:keymember(SInfo, 3, Checkouts) orelse
                                    Reload2 + 1 =:= Reload],
    if
        length(MaxRealSockets) >= MaxSockets ->
            true;
        Creators =:= 0 ->
            true;
        true ->
            false
    end.

check_all(#state{purge=Purge, sockets=Sockets}) ->
    [] =:= lists:dropwhile(fun({error, _}) ->
                                   true;
                              ({_, Reload} = SInfo) when Reload >= Purge ->
                                   check(SInfo) =:= ok;
                              ({_, Reload} = SInfo) when Reload < Purge ->
                                   check(SInfo) =/= ok
                           end, Sockets).
