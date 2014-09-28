%%-------------------------------------------------------------------
%%
%% Copyright (c) 2014, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
-module(sd_watcher).

-behaviour(gen_fsm).

%% public api

-export([start_link/4]).
-export([init_ack/2]).

%% register api

-export([register_name/2]).
-export([unregister_name/1]).
-export([whereis_name/1]).

%% gen api

-export([init_it/6]).

%% gen_fsm api

-export([init/1]).
-export([init/2]).
-export([init/3]).
-export([wait_ack/2]).
-export([wait_ack/3]).
-export([watch/2]).
-export([watch/3]).
-export([shutdown/2]).
-export([shutdown/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([format_status/2]).
-export([code_change/4]).
-export([terminate/3]).

%% types

-type name() :: {sock_drawer:id(), {sd_creator, {reference(), pos_integer()}}}.

-record(state, {id, pool, pool_ref, start_ref, ack_ref, socket, handler_sups,
                creators, monitors=sd_monitors:new()}).

%% public api

-spec start_link(Size, Id, PRef, Socket) -> {ok, Pid} | {error, Reason} when
      Size :: non_neg_integer(),
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Socket :: term(),
      Pid :: pid(),
      Reason :: term().
start_link(Size, Id, PRef, Socket) ->
    gen:start(?MODULE, link, {via, sd_reg, {Id, {?MODULE, PRef}}}, ?MODULE,
              {Id, PRef, Socket, Size}, []).


-spec init_ack(Watcher, ARef) -> ok when
      Watcher :: pid(),
      ARef :: reference().
init_ack(Watcher, ARef) ->
    gen_fsm:send_event(Watcher, {init_ack, ARef}).

%% register api

-spec register_name(Name, Pid) -> yes | no when
      Name :: name(),
      Pid :: pid().
register_name({{_SDName, Ref} = Id, {sd_creator, {PRef, N}}}, Pid)
  when node(Ref) =:= node() andalso node(Pid) =:= node() ->
    gen_fsm:sync_send_event({via, sd_reg, {Id, {?MODULE, PRef}}},
                            {register, PRef, N, Pid}).

-spec unregister_name(Name) -> Info when
      Name :: name(),
      Info :: boolean().
unregister_name({{_SDName, Ref} = Id, {sd_creator, {PRef, N}}})
  when node(Ref) =:= node() ->
    gen_fsm:sync_send_event({via, sd_reg, {Id, {?MODULE, PRef}}},
                            {unregister, PRef, N}).

-spec whereis_name(Name) -> Pid | undefined when
      Name :: name(),
      Pid :: pid().
whereis_name({{_SDName, Ref} = Id, {sd_creator, {PRef, N}}})
  when node(Ref) =:= node() ->
    Watcher = {via, sd_reg, {Id, {?MODULE, PRef}}},
    try gen_fsm:sync_send_all_state_event(Watcher, {whereis, PRef, N}) of
        Pid ->
            Pid
    catch
        exit:{noproc, {gen_fsm, send_sync_event, _Args}} ->
            undefined
    end.

%% gen api

init_it(Starter, _Parent, Name, ?MODULE, {Id, PRef, Socket, Size}, Opts) ->
    try init_it(Id, PRef, Starter, Socket, Size) of
        {ok, State} ->
            gen_fsm:enter_loop(?MODULE, Opts, init, State, Name)
    catch
        error:Reason ->
            Reason2 = {Reason, erlang:get_stacktrace()},
            % Don't need to unregister as Name is unique, so no race condition
            % re-registering name.
            proc_lib:init_ack(Starter, {error, Reason2}),
            exit(Reason2);
        exit:Reason ->
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason)
    end.

init_it(Id, PRef, Starter, Socket, Size) ->
    HandlerSups = start_handler_sups(Id, PRef),
    {_Pid, SRef} = spawn_opt(fun() ->
                                     start_creators(Id, PRef, Socket,
                                                    HandlerSups, Size)
                             end, [link, monitor]),
    Creators = array:new([{size, Size}, {fixed, true}]),
    {ok, #state{id=Id, pool=Starter, pool_ref=PRef, start_ref=SRef,
                socket=Socket, handler_sups=HandlerSups, creators=Creators}}.

start_handler_sups(Id, PRef) ->
    N = erlang:system_info(schedulers),
    start_handler_sups(Id, PRef, N, []).

start_handler_sups(_Id, _PRef, 0, HandlerSups) ->
    lists:reverse(HandlerSups);
start_handler_sups(Id, PRef, N, HandlerSups) ->
    case sd_handler_supersup:start_handler_sup(Id, PRef, N) of
        {ok, Pid} ->
            start_handler_sups(Id, PRef, N-1, [Pid | HandlerSups]);
        {error, Reason} ->
            exit({shutdown, {failed_to_start_child, sd_handler_sup, Reason}})
    end.

start_creators(_Id, _PRef, _Socket, _HandlerSups, 0) ->
    exit(normal);
start_creators(Id, PRef, Socket, HandlerSups, N) ->
    case sd_creator_sup:start_creator(Id, PRef, N, Socket, HandlerSups) of
        {ok, _Pid} ->
            start_creators(Id, PRef, Socket, HandlerSups, N-1);
        {error, Reason} ->
            exit({shutdown, {failed_to_start_child, sd_creator, Reason}})
    end.

%% gen_fsm api

init(_Args) ->
    {stop, enotsup}.

init(Event, State) ->
    {stop, {bad_event, Event}, State}.

init({register, PRef, N, Pid}, _From, #state{pool_ref=PRef} = State) ->
    {Reply, State2} = handle_register(N, Pid, State),
    {reply, Reply, init, State2};
init({unregister, PRef, N}, _From, #state{pool_ref=PRef} = State) ->
    {Reply, State2} = handle_unregister(N, State),
    {reply, Reply, init, State2}.

wait_ack({init_ack, ARef}, #state{ack_ref=ARef, creators=Creators} = State) ->
    proc_lib:init_ack({ok, self()}),
    demonitor(ARef, [flush]),
    case array:sparse_size(Creators) of
        0 ->
            {next_state, shutdown, State, 0};
        _Other ->
            {next_state, watch, State}
    end.

wait_ack(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

watch(Event, State) ->
    {stop, {bad_event, Event}, State}.

watch(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

shutdown(timeout, State) ->
    case count_handlers(State) of
        0 ->
            {stop, shutdown, State};
        _N ->
            {next_state, shutdown, State, 5000}
    end.

shutdown(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event({whereis, PRef, N}, _From, StateName,
                  #state{pool_ref=PRef} = State) ->
    {Reply, State2} = handle_whereis(N, State),
    {reply, Reply, StateName, State2}.

handle_info({'DOWN', SRef, _, _, normal}, init,
            #state{start_ref=SRef} = State) ->
    case handle_started(State) of
        {ok, State2} ->
            {next_state, wait_ack, State2};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info({'DOWN', ARef, _, _, Reason}, wait_ack,
            #state{ack_ref=ARef} = State) ->
    {stop, {shutdown, {bad_manager, Reason}}, State};
handle_info({'DOWN', MRef, _, Pid, normal}, StateName, State) ->
    {_N, #state{creators=Creators} = State2} = handle_down(MRef, Pid, State),
    case array:sparse_size(Creators) of
        0 ->
            {next_state, shutdown, State2, 0};
        _Other ->
            {next_state, StateName, State}
    end;
handle_info({'DOWN', MRef, _, Pid, Reason}, _StateName,
            #state{id=Id, pool_ref=PRef} = State) ->
    {N, State2} = handle_down(MRef, Pid, State),
    Name = {Id, {sd_creator, {PRef, N}}},
    {stop, {shutdown, {bad_creator, Name, Reason}}, State2};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

format_status(normal, [_PDict, #state{} = State]) ->
    [{data, [{"StateData", format_state(State)}]}];
format_status(terminate, [_PDict, #state{} = State]) ->
    format_state(State).

format_state(#state{} = State) ->
    SKeys = record_info(fields, state),
    [state | SValues] = tuple_to_list(State),
    lists:zip(SKeys, SValues).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(shutdown, shutdown, #state{id=Id, pool=Pool}) ->
    % This will call the supervisor of our parent to terminate our parent, so
    % will never return as parent will send a shutdown exit signal (and not
    % trapping exits). Thus our exit signal will still be shutdown.
    ok = sd_pool_sup:terminate_pool(Id, Pool);
terminate(_Reason, _StateName, _State) ->
    ok.

%% internal

handle_register(N, Pid, #state{creators=Creators, monitors=Monitors} = State) ->
    case array:get(N-1, Creators) of
        undefined ->
            {MRef, Monitors2} = sd_monitors:monitor(N, Pid, Monitors),
            Creators2 = array:set(N-1, {Pid, MRef}, Creators),
            {yes, State#state{creators=Creators2, monitors=Monitors2}};
        % This should NOT happen?! Will get exit signal soon after anyway.
        {_OldPid, _OldMRef} ->
            {no, State}
    end.

%% Could crash on unregister but will get a better error if a creator fails to
%% start by waiting for the starter pid to exit with the reason the creator
%% failed.
handle_unregister(N, #state{creators=Creators, monitors=Monitors} = State) ->
    case array:get(N-1, Creators) of
        {Pid, MRef} ->
            Creators2 = array:reset(N-1, Creators),
            {Info, Monitors2} = sd_monitors:demonitor(MRef, Pid, Monitors),
            {Info, State#state{creators=Creators2, monitors=Monitors2}};
        undefined ->
            {false, State}
    end.

handle_whereis(N, #state{creators=Creators} = State) ->
    case array:get(N-1, Creators) of
        {Pid, _MRef} ->
            ct:log("Found ~p", [N]),
            {Pid, State};
        undefined ->
            {undefined, State}
    end.

handle_down(MRef, Pid, #state{creators=Creators, monitors=Monitors} = State) ->
    {N, Monitors2} = sd_monitors:erase(MRef, Pid, Monitors),
    Creators2 = array:reset(N-1, Creators),
    {N, State#state{creators=Creators2, monitors=Monitors2}}.

count_handlers(#state{handler_sups=HandlerSups}) ->
    Count = fun(Pid, Acc) ->
                    sd_handler_sup:count_handlers(Pid) + Acc
            end,
    lists:foldl(Count, 0, HandlerSups).

handle_started(#state{id=Id, pool_ref=PRef, creators=Creators} = State) ->
    Pids = fun(_N, {Pid, _MRef}, Acc) -> [Pid | Acc] end,
    CreatorsList = array:sparse_foldr(Pids, [], Creators),
    case sd_manager:join(Id, PRef, CreatorsList) of
        {ok, ARef} ->
            {ok, State#state{ack_ref=ARef}};
        {error, Reason} ->
            Reason2 = {shutdown, {failed_to_start_pool, PRef, Reason}},
            proc_lib:init_ack({error, Reason2}),
            {error, Reason2}
    end.
