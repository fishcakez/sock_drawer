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
-module(sd_worker).

%% public api

-export([checkout/4]).
-export([stop/2]).

% public api

checkout(Handler, HRef, Client, CRef) ->
    gen_fsm:send_event(Handler, {checkout, HRef, Client, CRef}).

stop(Handler, HRef) ->
    gen_fsm:send_event(Handler, {stop, HRef}).
