-module(sd_simple_statem).

-include_lib("proper/include/proper.hrl").

-export([quickcheck/0]).
-export([quickcheck/1]).

-export([start_link/2]).
-export([simple_start_link/2]).
-export([init/1]).

-export([start_sd/2]).
-export([stop_sd/1]).
-export([connect/1]).
-export([close/1]).
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
                old_creators=0, max_sockets, old_max_sockets=0, sockets=[]}).

quickcheck() ->
    quickcheck([]).

quickcheck(Opts) ->
    proper:quickcheck(prop_simple(), Opts).

start_link(NumCreators, MaxSockets) ->
    sock_drawer:start_link(?MODULE, {sock_drawer, NumCreators, MaxSockets}, []).

simple_start_link(MaxSockets, Id) ->
    sd_simple:start_link(Id, ?MODULE, {sd_simple, MaxSockets}, []).

init({sock_drawer, NumCreators, MaxSockets}) ->
    Shutdown = case get(manager) of
                   undefined -> 5000;
                   A -> 5000 + A
               end,
    MaxSockets2 = case get(max_sockets) of
                      undefined -> MaxSockets;
                      B -> B
                  end,
    Manager = {manager, {?MODULE, simple_start_link, [MaxSockets2]},
               permanent, Shutdown, worker, [?MODULE, sd_simple]},
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
    Handler = {handler, {sdt_handler, start_link, [Reload]},
               temporary, 5000, worker, [sdt_handler]},
    NumCreators2 = case get(creators) of
                       undefined -> NumCreators;
                       E -> E
                   end,
    {ok, {{{sd_tcp, accept, {{127,0,0,1}, 0}}, NumCreators2, 0, 1},
           [Manager, Targeter, Creator, Handler]}};
init({sd_simple, MaxSockets}) ->
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
            case gen_tcp:recv(Socket, 0, 200) of
                {ok, <<"hi", Reload:32>>} ->
                    {Socket, Reload};
                {error, _Reason} = Error ->
                    gen_tcp:close(Socket),
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

close({error, _Reason}) ->
    ok;
close({Socket, _Reload}) ->
    _ = gen_tcp:shutdown(Socket, write),
    gen_tcp:recv(Socket, 0, 200).

check({error, _Reason}) ->
    {error, closed};
check({Socket, _Reload}) ->
    _ = gen_tcp:send(Socket, "hello"),
    case gen_tcp:recv(Socket, 0, 200) of
        {ok, <<"hello">>} ->
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
    Result.

change_max_sockets(Id, MaxSockets) ->
    Name = {via, sd_reg, {Id, sd_manager}},
    sys:suspend(Name),
    sys:replace_state(Name,
                      fun(State) -> put(max_sockets, MaxSockets), State end),
    Result = sys:change_code(Name, ?MODULE, undefined, undefined),
    sys:resume(Name),
    Result.

purge(Pid) ->
    sock_drawer:purge(Pid).

creators() ->
    choose(0, 3).

max_sockets() ->
    oneof([0, 1, 2, 3, infinity]).

initial_state() ->
    #state{}.

command(#state{pid=undefined}) ->
    {call, ?MODULE, start_sd, [creators(), max_sockets()]};
command(#state{pid=Pid, reload=Reload, id=Id, sockets=Sockets}) ->
    frequency([{10, {call, ?MODULE, connect, [Id]}}] ++
              [{8, {call, ?MODULE, close, [elements(Sockets)]}} ||
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
next_state(#state{sockets=Sockets} = State, _V,
           {call, ?MODULE, close, [SInfo]}) ->
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
postcondition(_State, {call, ?MODULE, close, [_]}, Result) ->
    Result =/= {error, timeout};
postcondition(#state{purge=Purge}, {call, ?MODULE, check, [SInfo]},
              Result) ->
    case SInfo of
        {error, _Reason} ->
            Result =:= {error, closed};
        {_Socket, Reload} when Purge =< Reload ->
            Result =:= ok;
        {_Socket, Reload} when Purge > Reload ->
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

can_connect(#state{purge=Purge, creators=Creators, old_creators=OldCreators,
                   sockets=Sockets, max_sockets=MaxSockets,
                   old_max_sockets=OldMaxSockets}) ->
    MaxSockets2 = max(MaxSockets, OldMaxSockets),
    RealSockets = [Socket || {Socket, Reload} <- Sockets,
                             is_port(Socket), Reload >= Purge],
    if
        length(RealSockets) >= MaxSockets2 ->
            false;
        Creators > 0 ->
            true;
        OldCreators > 0 ->
            true;
        true ->
            false
    end.

maybe_no_connect(#state{purge=Purge, creators=Creators, sockets=Sockets,
                        max_sockets=MaxSockets}) ->
    RealSockets = [Socket || {Socket, Reload} <- Sockets,
                             is_port(Socket), Reload >= Purge],
    if
        length(RealSockets) >= MaxSockets ->
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
