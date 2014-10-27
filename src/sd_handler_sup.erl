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
-module(sd_handler_sup).

-behaviour(supervisor).

%% public api

-export([start_link/4]).
-export([start_handler/2]).
-export([acquire/4]).
-export([terminate_handler/2]).
-export([count_handlers/1]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

%% public api

-spec start_link(Id, PRef, Handler, N) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Handler :: supervisor:child_spec(),
      N :: pos_integer(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, PRef, Handler, N) ->
    Name = {via, sd_reg, {Id, {?MODULE, {PRef, N}}}},
    gen_server:start_link(Name, ?MODULE, {gen_server, Name, PRef, Handler}, []).

-spec start_handler(Sup, Manager) ->
    {ok, Pid} | {ok, Pid, Info} | {error, Reason} when
      Sup :: pid(),
      Manager :: pid(),
      Pid :: pid(),
      Info :: term(),
      Reason :: term().
start_handler(Sup, Manager) ->
    supervisor:start_child(Sup, [Manager]).

-spec acquire(Sup, PRef, Manager, MRef) -> ok when
      Sup :: pid(),
      PRef :: reference(),
      Manager :: pid(),
      MRef :: reference().
acquire(Sup, PRef, Manager, MRef) ->
    gen_server:cast(Sup, {acquire, PRef, Manager, self(), MRef}).

-spec terminate_handler(Sup, Pid) -> ok | {error, not_found} when
      Sup :: pid(),
      Pid :: pid().
terminate_handler(Sup, Pid) ->
    supervisor:terminate_child(Sup, Pid).

-spec count_handlers(Sup) -> Count when
      Sup :: pid(),
      Count :: non_neg_integer().
count_handlers(Sup) ->
    Counts = supervisor:count_children(Sup),
    proplists:get_value(active, Counts, 0).

%% gen_server api

init({gen_server, Name, PRef, Handler}) ->
    supervisor:init({Name, ?MODULE,  {supervisor, PRef, Handler}});
init({supervisor, PRef, Handler}) ->
    Handler2 = sd_util:append_args(Handler, [PRef]),
    {ok, {{simple_one_for_one, 0, 1}, [Handler2]}}.

handle_call(Request, From, State) ->
    supervisor:handle_call(Request, From, State).

handle_cast({acquire, PRef, Manager, Creator, MRef}, State) ->
    From = {self(), ?MODULE},
    case supervisor:handle_call({start_child, [Manager]}, From, State) of
        {reply, {ok, Pid}, State2} when is_pid(Pid) ->
            HInfo = {Pid, self(), Pid},
            sd_manager:acquire(Manager, PRef, Creator, MRef, HInfo),
            {noreply, State2};
        {reply, {ok, Pid, Pid2}, State2} when is_pid(Pid2) ->
            HInfo = {Pid2, self(), Pid},
            sd_manager:acquire(Manager, PRef, Creator, MRef, HInfo),
            {noreply, State2};
        {reply, {ok, Pid, _Info}, State2} ->
            HInfo = {Pid, self(), Pid},
            sd_manager:acquire(Manager, PRef, Creator, MRef, HInfo),
            {noreply, State2};
        {reply, {ok, undefined}, State2} ->
            sd_creator:stop(Creator, MRef),
            {noreply, State2};
        {reply, {error, Reason}, State2} ->
            Reason2 = {failed_to_start_child, handler, Reason},
            sd_creator:stop(Creator, MRef, Reason2),
            {noreply, State2}
    end;
handle_cast(Request, State) ->
    supervisor:handle_cast(Request, State).

handle_info(Info, State) ->
    supervisor:handle_info(Info, State).

code_change(OldVsn, State, Extra) ->
    supervisor:code_change(OldVsn, State, Extra).

terminate(Reason, State) ->
    supervisor:terminate(Reason, State).
