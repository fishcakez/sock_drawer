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
-module(sdt_queue).

-behaviour(sock_drawer).

%% public api

-export([start_link/2]).

%% sd_simple api

-export([init/1]).

%% public api

-spec start_link(MaxSockets, Id) -> {ok, Pid} | {error, Reason} when
      MaxSockets :: non_neg_integer() | infinity,
      Id :: sock_drawer:id(),
      Pid :: pid(),
      Reason :: term().
start_link(MaxSockets, Id) ->
    sd_queue:start_link(Id, ?MODULE, MaxSockets, [{debug, [trace, {log, 20}]}]).

%% sd_simple api

init(MaxSockets) ->
    {ok, MaxSockets}.
