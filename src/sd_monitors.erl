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
-module(sd_monitors).

%% public api

-export([new/0]).
-export([monitor/3]).
-export([demonitor/3]).
-export([erase/3]).
-export([format/1]).

%% types

-type name() :: term().
-opaque monitors() :: dict:dict(reference(), {name(), pid()}).

-export_type([monitors/0]).

%% public api

-spec new() -> Monitors when
      Monitors :: monitors().
new() ->
    dict:new().

-spec monitor(Name, Pid, Monitors) -> {MRef, Monitors2} when
      Name :: name(),
      Pid :: pid(),
      Monitors :: monitors(),
      MRef :: reference(),
      Monitors2 :: monitors().
monitor(Name, Pid, Monitors) ->
    MRef = monitor(process, Pid),
    {MRef, dict:store(MRef, {Name, Pid}, Monitors)}.

-spec demonitor(MRef, Pid, Monitors) -> {Info, Monitors2} when
      MRef :: reference(),
      Pid :: pid(),
      Monitors :: monitors(),
      Info :: boolean(),
      Monitors2 :: monitors().
%% Technically it's possible that a supervisor receives the Pid's exit signal
%% and restarts a process before this server is sent the 'DOWN' from the
%% monitor. If demonitor/2 returns true it should be this case so check the
%% (local) process is not alive (i.e. exiting or exited).
demonitor(MRef, Pid, Monitors) ->
    Info = demonitor(MRef, [flush, info]) andalso is_process_alive(Pid),
    {Info, dict:erase(MRef, Monitors)}.

-spec erase(MRef, Pid, Monitors) -> {Name, Monitors2} when
      MRef :: reference(),
      Pid :: pid(),
      Monitors :: monitors(),
      Name :: name(),
      Monitors2 :: monitors().
erase(MRef, Pid, Monitors) ->
    {Name, Pid} = dict:fetch(MRef, Monitors),
    {_Info, Monitors2} = demonitor(MRef, Pid, Monitors),
    {Name, Monitors2}.

-spec format(Monitors) -> [{Name, Pid, MRef}] when
      Monitors :: monitors(),
      Name :: name(),
      Pid :: pid(),
      MRef :: reference().
%% Format the Monitors dict so it is readable.
format(Monitors) ->
    ToList = fun({MRef, {Name, Pid}}, Acc) -> [{Name, Pid, MRef} | Acc] end,
    dict:fold(ToList, [], Monitors).
