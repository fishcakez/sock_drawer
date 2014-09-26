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
-export([start_handler/1]).
-export([terminate_handler/2]).
-export([count_handlers/1]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id, PRef, Handler, N) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Handler :: supervisor:child_spec(),
      N :: pos_integer(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, PRef, Handler, N) ->
    supervisor:start_link({via, sd_reg, {Id, {?MODULE, {PRef, N}}}},
                          ?MODULE, {PRef, Handler}).

-spec start_handler(Sup) -> {ok, Pid} | {ok, Pid, Info} | {error, Reason} when
      Sup :: pid(),
      Pid :: pid(),
      Info :: term(),
      Reason :: term().
start_handler(Sup) ->
    supervisor:start_child(Sup, []).

-spec terminate_handler(Sup, Pid) -> ok | {error, not_found} when
      Sup :: pid(),
      Pid :: pid().
terminate_handler(Sup, Pid) ->
    supervisor:terminate_child(Sup, Pid).

-spec count_handlers(Sup) -> Count when
      Sup :: pid(),
      Count :: non_neg_integer().
count_handlers(Sup) ->
    Counts = supervisor:counter_children(Sup),
    proplists:get_value(active, Counts, 0).

%% supervisor api

init({PRef, Handler}) ->
    Handler2 = sd_util:append_args(Handler, [PRef]),
    {ok, {{simple_one_for_one, 0, 1}, [Handler2]}}.
