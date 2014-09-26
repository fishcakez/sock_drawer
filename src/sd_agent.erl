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
-module(sd_agent).

-behaviour(gen_server).

%% public api

-export([start_link/2]).
-export([old_pools/1]).

%% register api

-export([register_name/2]).
-export([unregister_name/1]).
-export([whereis_name/1]).

%% data api

-export([store/3]).
-export([find/2]).
-export([erase/2]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([format_status/2]).
-export([code_change/3]).

%% types

-type internal_name() :: module() |
                         {module(), reference() | {reference(), pos_integer()}}.
-type name() :: {sock_drawer:id(), internal_name()}.

-record(state, {id :: sockdrawer:id(),
                ref :: reference(),
                sock_info :: sockdrawer:sock_info(),
                data = dict:new() :: dict:dict(),
                procs = dict:new() :: dict:dict(),
                monitors = sd_monitors:new() :: sd_monitors:monitors(),
                reloader_ref = make_ref() :: reference(),
                pool_ref = make_ref() :: reference()}).

%% public api

-spec start_link(Id, SockInfo) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      SockInfo :: sock_drawer:sock_info(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, SockInfo) ->
    Args = {Id, SockInfo, self()},
    gen_server:start_link({via, sd_reg, {Id, ?MODULE}}, ?MODULE, Args, []).

-spec old_pools(Id) -> [Pool] when
      Id :: sock_drawer:id(),
      Pool :: pid().
old_pools({_SDName, Ref} = Id) ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}}, {old_pools, Ref}).

%% register api

-spec register_name(Name, Pid) -> yes | no when
      Name :: name(),
      Pid :: pid().
register_name({_Id, {sd_creator, _}} = Name, Pid) ->
    sd_watcher:register_name(Name, Pid);
register_name({{_SDName, Ref} = Id, Proc}, Pid)
  when node(Ref) =:= node() andalso node(Pid) =:= node() ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}},
                    {register, Ref, Proc, Pid}).

-spec unregister_name(Name) -> Info when
      Name :: name(),
      Info :: boolean().
unregister_name({_Id, {sd_creator, _}} = Name) ->
    sd_watcher:unregister_name(Name);
unregister_name({{_SDName, Ref} = Id, Proc}) when node(Ref) =:= node() ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}},
                    {unregister, Ref, Proc}).

-spec whereis_name(Name) -> Pid | undefined when
      Name :: name(),
      Pid :: pid().
whereis_name({_Id, {sd_creator, _}} = Name) ->
    sd_watcher:whereis_name(Name);
whereis_name({{_SDName, Ref} = Id, Proc}) ->
    try gen_server:call({via, sd_reg, {Id, ?MODULE}},
                        {whereis, Ref, Proc}) of
        Pid ->
            Pid
    catch
        exit:{noproc, {gen_server, call, _Args}} ->
            undefined
    end.

%% data api

-spec store(Id, Key, Value) -> ok when
      Id :: sock_drawer:id(),
      Key :: term(),
      Value :: term().
store({_SDName, Ref} = Id, Key, Value) ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}},
                    {store, Ref, Key, Value}).

-spec find(Id, Key) -> {ok, Value} | error when
      Id :: sock_drawer:id(),
      Key :: term(),
      Value :: term().
find({_SDName, Ref} = Id, Key) ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}}, {find, Ref, Key}).

-spec erase(Id, Key) -> ok when
      Id :: sock_drawer:id(),
      Key :: term().
erase({_SDName, Ref} = Id, Key) ->
    gen_server:call({via, sd_reg, {Id, ?MODULE}}, {erase, Ref, Key}).

%% gen_server api

init({{_SDName, Ref} = Id, SockInfo, Parent}) ->
    State = #state{id=Id, ref=Ref, sock_info=SockInfo},
    {yes, State2} = handle_register(sock_drawer, Parent, State),
    {ok, State2}.

handle_call({register, Ref, Proc, Pid}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_register(Proc, Pid, State),
    {reply, Reply, State2};
handle_call({unregister, Ref, Proc}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_unregister(Proc, State),
    {reply, Reply, State2};
handle_call({whereis, Ref, Proc}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_whereis(Proc, State),
    {reply, Reply, State2};
handle_call({store, Ref, Key, Value}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_store(Key, Value, State),
    {reply, Reply, State2};
handle_call({find, Ref, Key}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_find(Key, State),
    {reply, Reply, State2};
handle_call({erase, Ref, Key}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_erase(Key, State),
    {reply, Reply, State2};
handle_call({old_pools, Ref}, _From, #state{ref=Ref} = State) ->
    {Reply, State2} = handle_old_pools(State),
    {reply, Reply, State2}.

handle_cast(Cast, State) ->
    {noreply, {bad_cast, Cast}, State}.

handle_info({'DOWN', MRef, _, Pid, _}, State) ->
    State2 = handle_down(MRef, Pid, State),
    {noreply, State2};
handle_info(Info, #state{id=Id} = State) ->
    Name = {Id, ?MODULE},
    error_logger:error_msg("~p (~p) received unexpected message: ~p~n",
                           [Name, self(), Info]),
    {noreply, State}.

format_status(normal, [_PDict, #state{} = State]) ->
    [{data, [{"StateData", format_state(State)}]}];
format_status(terminate, [_PDict, #state{} = State]) ->
    format_state(State).

format_state(#state{data=Data, procs=Procs, monitors=Monitors} = State) ->
    SKeys = record_info(fields, state),
    State2 = State#state{data=dict:to_list(Data), procs=dict:to_list(Procs),
                         monitors=sd_monitors:format(Monitors)},
    [state | SValues] = tuple_to_list(State2),
    lists:zip(SKeys, SValues).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

handle_register({sd_reloader, RRef} = Proc, Pid, State) ->
    case do_register(Proc, Pid, State) of
        {yes, State2} ->
            {yes, State2#state{reloader_ref=RRef}};
        {no, _State2} = No ->
            No
    end;
handle_register({sd_pool, {RRef, PRef}} = Proc, Pid,
                #state{reloader_ref=RRef} = State) ->
    case do_register(Proc, Pid, State) of
        {yes, State2} ->
            {yes, State2#state{pool_ref=PRef}};
        {no, _State2} = No ->
            No
    end;
handle_register(Proc, Pid, State) when is_atom(Proc) ->
    do_register(Proc, Pid, State);
handle_register({_Mod, PRef} = Proc, Pid, #state{pool_ref=PRef} = State) ->
    do_register(Proc, Pid, State);
handle_register({Mod, {PRef, _Id}} = Proc, Pid,
                #state{pool_ref=PRef} = State) when Mod =/= sd_pool ->
    do_register(Proc, Pid, State).

do_register(Proc, Pid, #state{procs=Procs, monitors=Monitors} = State) ->
    case dict:find(Proc, Procs) of
        error ->
            {MRef, Monitors2} = sd_monitors:monitor(Proc, Pid, Monitors),
            Procs2 = dict:store(Proc, {Pid, MRef}, Procs),
            {yes, State#state{procs=Procs2, monitors=Monitors2}};
        {ok, {OldPid, MRef}} ->
            reregister(Proc, Pid, MRef, OldPid, State)
    end.

reregister(Proc, Pid, MRef, OldPid,
           #state{procs=Procs, monitors=Monitors} = State) ->
    case sd_monitors:demonitor(MRef, OldPid, Monitors) of
        {false, Monitors2} ->
            {MRef2, Monitors3} = sd_monitors:monitor(Proc, Pid, Monitors2),
            Replace = fun(_) -> {Pid, MRef2} end,
            Procs2 = dict:update(Proc, Replace, Procs),
            {yes, State#state{procs=Procs2, monitors=Monitors3}};
        {true, Monitors} ->
            {MRef2, Monitors2} = sd_monitors:monitor(Proc, Pid, Monitors),
            Update = fun({OldPid2, _}) when OldPid2 =:= OldPid ->
                             {OldPid2, MRef2}
                     end,
            Procs2 = dict:update(Proc, Update, Procs),
            {no, State#state{procs=Procs2, monitors=Monitors2}}
    end.

handle_unregister({sd_pool, PRef} = Proc, #state{pool_ref=PRef, procs=Procs,
                                                 monitors=Monitors} = State) ->
    {Pid, MRef} = dict:fetch(Proc, Procs),
    Procs2 = dict:erase(Proc, Procs),
    {Info, Monitors2} = sd_monitors:demonitor(MRef, Pid, Monitors),
    {Info, State#state{pool_ref=make_ref(), procs=Procs2, monitors=Monitors2}};
handle_unregister(Proc, #state{procs=Procs, monitors=Monitors} = State) ->
    case dict:find(Proc, Procs) of
        {ok, {Pid, MRef}} ->
            Procs2 = dict:erase(Proc, Procs),
            {Info, Monitors2} = sd_monitors:demonitor(MRef, Pid, Monitors),
            {Info, State#state{procs=Procs2, monitors=Monitors2}};
        error ->
            {false, State}
    end.

handle_whereis(Proc, #state{procs=Procs} = State) ->
    case dict:find(Proc, Procs) of
        {ok, {Pid, MRef}} ->
            whereis_alive(Proc, Pid, MRef, State);
        error ->
            {undefined, State}
    end.

whereis_alive(Proc, Pid, MRef,
              #state{procs=Procs, monitors=Monitors} = State) ->
    case is_process_alive(Pid) of
        true ->
            {Pid, State};
        false ->
            Procs2 = dict:erase(Proc, Procs),
            {_Info, Monitors2} = sd_monitors:demonitor(MRef, Pid, Monitors),
            {undefined, State#state{procs=Procs2, monitors=Monitors2}}
    end.

handle_store(Key, Value, #state{data=Data} = State) ->
    Data2 = dict:store(Key, Value, Data),
    {ok, State#state{data=Data2}}.

handle_find(Key, #state{data=Data} = State) ->
    {dict:find(Key, Data), State}.

handle_erase(Key, #state{data=Data} = State) ->
    Data2 = dict:erase(Key, Data),
    {ok, State#state{data=Data2}}.

handle_old_pools(#state{reloader_ref=RRef, procs=Procs} = State) ->
    OldPool = fun({sd_pool, {RRef2, _}}, {Pid, _}, Acc) when RRef2 =/= RRef ->
                      [Pid | Acc];
                 (_, _, Acc) ->
                      Acc
              end,
    {dict:fold(OldPool, [], Procs), State}.

handle_down(MRef, Pid,
            #state{pool_ref=PRef, procs=Procs, monitors=Monitors} = State) ->
    case sd_monitors:erase(MRef, Pid, Monitors) of
        {{sd_pool, PRef} = Proc, Monitors2} ->
            Procs2 = dict:erase(Proc, Procs),
            State#state{pool_ref=make_ref(), procs=Procs2, monitors=Monitors2};
        {Proc, Monitors2} ->
            Procs2 = dict:erase(Proc, Procs),
            State#state{procs=Procs2, monitors=Monitors2}
    end.
