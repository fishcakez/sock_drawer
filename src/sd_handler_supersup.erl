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
-module(sd_handler_supersup).

-behaviour(supervisor).

%% public api

-export([start_link/3]).
-export([start_handler_sup/3]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id, PRef, Handler) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Handler :: supervisor:child_spec(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, PRef, Handler) ->
    supervisor:start_link({via, sd_reg, {Id, {?MODULE, PRef}}}, ?MODULE,
                          {Id, PRef, Handler}).

-spec start_handler_sup(Id, PRef, N) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      N :: pos_integer(),
      Pid :: pid(),
      Reason :: term().
start_handler_sup(Id, PRef, N) ->
    supervisor:start_child({via, sd_reg, {Id, {?MODULE, PRef}}}, [N]).

%% supervisor api

init({Id, PRef, Handler}) ->
    HandlerSup = {sd_handler_sup,
                  {sd_handler_sup, start_link, [Id, PRef, Handler]},
                  permanent, 3000, worker, [sd_handler_sup]},
    {ok, {{simple_one_for_one, 0, 1}, [HandlerSup]}}.
