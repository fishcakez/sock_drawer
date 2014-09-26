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
-module(sd_seek).

-behaviour(gen_server).

%% public api

-export([start_link/0]).
-export([new/2]).
-export([info/1]).
-export([close/1]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% public api

-spec start_link() -> {ok, Pid} | {error, Reason} when
      Pid :: pid(),
      Reason :: term().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec new(Target, Opts) -> MRef when
      Target :: term(),
      Opts :: list(),
      MRef :: reference().
new(Target, Opts) ->
    gen_server:call(?MODULE, {new, self(), Target, Opts}).

-spec info(MRef) -> {ok, {Target, Opts}} | {error, closed} when
      MRef :: reference(),
      Target :: term(),
      Opts :: list().
info(MRef) ->
    case ets:lookup(?MODULE, MRef) of
        [{_MRef, Target, Opts}] ->
            {ok, {Target, Opts}};
        [] ->
            {error, closed}
    end.

-spec close(MRef) -> ok when
      MRef :: reference().
close(MRef) ->
    gen_server:call(?MODULE, {close, MRef}).

%% gen_server api

init([]) ->
    process_flag(trap_exit, true),
    State = ets:new(?MODULE, [set, protected, named_table,
                              {read_concurrency, true}]),
    {ok, State}.

handle_call({new, Targeter, Target, Opts}, _From, State) ->
    {Reply, State2} = handle_new(Targeter, Target, Opts, State),
    {reply, Reply, State2};
handle_call({close, MRef}, _From, State) ->
    {Reply, State2} = handle_close(MRef, State),
    {reply, Reply, State2}.

handle_cast(Request, State) ->
    {stop, {bad_cast, Request}, State}.

handle_info({'DOWN', MRef, _, _, _}, State) ->
    {noreply, handle_down(MRef, State)};
handle_info({'EXIT', _, _}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, State) ->
    ets:delete(State),
    ok.

handle_new(Targeter, Target, Opts, State) ->
    MRef = monitor(process, Targeter),
    link(Targeter),
    true = ets:insert_new(State, {MRef, Target, Opts}),
    {MRef, State}.

handle_close(MRef, State) ->
    demonitor(MRef, [flush]),
    ets:delete(State, MRef),
    {ok, State}.

handle_down(MRef, State) ->
    ets:delete(State, MRef),
    State.
