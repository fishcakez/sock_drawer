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
-module(sd_tcp).

-export([listen/2]).
-export([accept/2]).
-export([setopts/2]).
-export([getaddrs/2]).
-export([connect/3]).
-export([close/1]).

listen({IP, Port}, Opts) ->
    gen_tcp:listen(Port, Opts ++ [{active, false}, {ifaddr, IP}, {port, Port}]).

accept(LSocket, Timeout) ->
    gen_tcp:accept(LSocket, Timeout).

setopts(Socket, Opts) ->
    inet:setopts(Socket, Opts).

getaddrs({IP, _Port}, _Timeout) ->
    inet:getaddrs(IP, inet).

connect({IP, Port}, Opts, Timeout) ->
    gen_tcp:connect(IP, Port, Opts ++ [{active, false}], Timeout).

close(Socket) ->
    gen_tcp:close(Socket).
