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
-module(sd_reg).

-behaviour(gen_server).

%% register api

-export([register_name/2]).
-export([unregister_name/1]).
-export([whereis_name/1]).

%% public api

-export([start_link/0]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([format_status/2]).
-export([terminate/2]).

%% types

-type internal_name() :: module() |
                         {module(), reference() | {reference(), pos_integer()}}.
-type name() :: {sock_drawer:id(), internal_name()}.

-record(state, {tab, monitors=sd_monitors:new()}).

%% register api

-spec register_name(Name, Pid) -> yes | no when
      Name :: name(),
      Pid :: pid().
%% Ref and Pid must be local.
register_name({{_SDName, Ref}, sd_agent}, Pid)
  when node(Ref) =:= node() andalso node(Pid) =:= node() ->
    gen_server:call(?MODULE, {register, Ref, Pid});
register_name({{_SDName, _Ref}, sd_agent} = Name, Pid) ->
    error(badarg, [Name, Pid]);
register_name(Name, Pid) ->
    sd_agent:register_name(Name, Pid).

-spec unregister_name(Name) -> Info when
      Name :: name(),
      Info :: boolean().
unregister_name({{_SDName, Ref}, sd_agent}) when node(Ref) =:= node() ->
    gen_server:call(?MODULE, {unregister, Ref});
unregister_name({{_SDName, _Ref}, sd_agent} = Name) ->
    error(badarg, [Name]);
unregister_name(Name) ->
    sd_agent:unregister_name(Name).

-spec whereis_name(Name) -> Pid | undefined when
      Name :: name(),
      Pid :: pid().
whereis_name({{_SDName, Ref}, sd_agent}) when node(Ref) =:= node() ->
    try ets:lookup_element(?MODULE, Ref, 2) of
        Pid ->
            whereis_alive(Pid)
    catch
        error:badarg ->
            undefined
    end;
%% Allow distributed lookup for debug.
whereis_name({{_SDName, Ref}, _IntName} = Name) when node(Ref) =/= node() ->
    try rpc:call(node(Ref), ?MODULE, whereis_name, [Name]) of
        Pid when is_pid(Pid) ->
            Pid;
        undefined ->
            undefined;
        {badrpc, _Reason} ->
            undefined
    catch
        exit:_Reason->
            undefined
    end;
whereis_name(Name) ->
    sd_agent:whereis_name(Name).

%% It is possible a supervisor will restart a process before it is removed from
%% the ets table. This check will prevent a start_link call from returning an
%% already_started error (before spawning a process) when the previous process
%% is not alive.
whereis_alive(Pid) ->
    case is_process_alive(Pid) of
        true  -> Pid;
        false -> undefined
    end.

%% public api

-spec start_link() -> {ok, Pid} | {error, Reason} when
      Pid :: pid(),
      Reason :: term().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server api

init([]) ->
    process_flag(trap_exit, true),
    Tab = ets:new(?MODULE, [set, public, named_table,
                            {read_concurrency, true}]),
    {ok, #state{tab=Tab}}.

handle_call({register, Ref, Pid}, _From, State) ->
    {Reply, State2} = handle_register(Ref, Pid, State),
    {reply, Reply, State2};
handle_call({unregister, Ref}, _From, State) ->
    {Reply, State2} = handle_unregister(Ref, State),
    {reply, Reply, State2}.

handle_cast(Cast, State) ->
    {stop, {bad_cast, Cast}, State}.

handle_info({'DOWN', MRef, _, Pid, _}, State) ->
    State2 = handle_down(MRef, Pid, State),
    {noreply, State2};
handle_info({'EXIT', _, _}, State) ->
    {noreply, State};
handle_info(Info, State) ->
    error_logger:error_msg("~p (~p) received unexpected message: ~p~n",
                           [?MODULE, self(), Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(normal, [_PDict, #state{monitors=Monitors}]) ->
    [{data, [{"State", sd_monitors:format(Monitors)}]}];
format_status(terminate, [_PDict, #state{monitors=Monitors}]) ->
    sd_monitors:format(Monitors).

terminate(_Reason, _State) ->
    ok.

%% internal

handle_register(Ref, Pid, #state{tab=Tab, monitors=Monitors} = State) ->
    case ets:lookup(Tab, Ref) of
        [] ->
            {MRef, Monitors2} = sd_monitors:monitor(Ref, Pid, Monitors),
            link(Pid),
            true = ets:insert_new(Tab, {Ref, Pid, MRef}),
            {yes, State#state{monitors=Monitors2}};
        [{_Ref, OldPid, MRef}] ->
            handle_reregister(Ref, Pid, MRef, OldPid, State)
    end.

handle_reregister(Ref, Pid, MRef, OldPid,
                  #state{tab=Tab, monitors=Monitors} = State) ->
    % OldPid should be down, so assume it is.
    case sd_monitors:demonitor(MRef, OldPid, Monitors) of
        {false, Monitors2} ->
            {MRef2, Monitors3} = sd_monitors:monitor(Ref, Pid, Monitors2),
            link(Pid),
            true = ets:update_element(Tab, Ref, [{2, Pid}, {3, MRef2}]),
            {yes, State#state{monitors=Monitors3}};
        % Oops the process is alive, remonitor it.
        {true, Monitors2} ->
            {MRef2, Monitors3} = sd_monitors:monitor(Ref, OldPid, Monitors2),
            true = ets:update_element(Tab, Ref, [{3, MRef2}]),
            {no, State#state{monitors=Monitors3}}
    end.

handle_unregister(Ref, #state{tab=Tab, monitors=Monitors} = State) ->
    case ets:lookup(Tab, Ref) of
        [{_Ref, Pid, MRef}] ->
            ets:delete(Tab, Ref),
            {Info, Monitors2} = sd_monitors:demonitor(MRef, Pid, Monitors),
            {Info, State#state{monitors=Monitors2}};
        [] ->
            {false, State#state{monitors=Monitors}}
    end.

handle_down(MRef, Pid, #state{tab=Tab, monitors=Monitors} = State) ->
    {Ref, Monitors2} = sd_monitors:erase(MRef, Pid, Monitors),
    ets:delete(Tab, Ref),
    State#state{monitors=Monitors2}.
