%% @author Konstantin Nikiforov <helllamer@gmail.com>
%% @copyright 2011 Konstantin Nikiforov
%% @doc Cron-like job manager extension for zotonic.

%% Copyright 2011 Konstantin Nikiforov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(resource_cron_admin).

-export([
    %% wm resource:
    is_authorized/2,
    event/2,

    %% comet:
    updates_listener_stream/1,
    updates_listener_stream_loop/1
]).

-include_lib("resource_html.hrl").

is_authorized(ReqData, Context) ->
    z_acl:wm_is_authorized(use, mod_cron, ReqData, Context).

html(Context) ->
    Template = z_context:get(template, Context),
    Selected = z_context:get(selected, Context, "admin_mod_cron"),
    Html     = z_template:render(Template, [{selected, Selected}], Context),
    %% subscribe for updates via comet
    (catch z_session_page:spawn_link(?MODULE, updates_listener_stream, [Context], Context)),
    z_context:output(Html, Context).


%% add new job
event({submit, insert_job, _TriggerId, _TargetId}, Context) ->
    Q = fun(Param) -> z_context:get_q(Param, Context) end,
    JobId = Q(id),
    %% parsing time definition into erlang term
    {ok,When} = parse_term(Q("when")),
    %% parse MFA
    {ok,M} = parse_term(Q("module")),
    {ok,F} = parse_term(Q("function")),
    {ok,A} = parse_term(ensure_list(Q("args"))),
    Task   = {When, {M,F,A}},
    case m_cron_job:insert(JobId, Task, Context) of
	{ok,_}	-> RA = [{dialog_close, []}, {reload, []}],
		   z_render:wire(RA, Context);
	E	-> EText = io_lib:format("Error: ~p", [E]),
		   z_render:growl_error(EText, Context)
    end;

%% delete existing job
event({postback, {delete_job, [{job_id, JobId}]}, _TriggerId, _TargetId}, Context) ->
    ?DEBUG(m_cron_job:delete(JobId, Context)),
    Context.


%% erl_parse wants to see dot at the end. Add the dot:
ensure_dot_end(Str) ->
    case lists:last(Str) of
	$. -> Str;
	_  -> Str ++ "."
    end.

parse_term(Str) ->
    Str1 = ensure_dot_end(Str),
    try
	{ok,Tokens,_} = erl_scan:string(Str1),
	{ok,_Term} = erl_parse:parse_term(Tokens)
    catch _:_ ->
	{error, Str}
    end.


ensure_list(Str) ->
    [ $[ | Str] ++ "]".


%% receive comet updates
updates_listener_stream(Context) ->
    process_flag(trap_exit, true),
    listener_stream_subscribe(Context),
    updates_listener_stream_loop(Context).

updates_listener_stream_loop(Context) ->
    receive
	{'$gen_cast', _} ->
	    rerender_job_list(Context),
	    ?MODULE:updates_listener_stream_loop(Context);

	{'EXIT', _} ->
	    listener_stream_unsubscribe(Context)

	after 10*60*1000 ->
	    listener_stream_unsubscribe(Context)

    end.

-define(UPDATES_LISTENER_EVENTS_LIST, [
	cron_job_inserted, cron_job_deleted, cron_job_nextrun %, cron_job_executed
    ]).

%% comet: subscribe for z_notifier events
listener_stream_subscribe(Context) ->
    Self = self(),
    lists:foreach(fun(Event) -> z_notifier:observe(Event, Self, Context) end, ?UPDATES_LISTENER_EVENTS_LIST).

%% comet: unsubscribe from z_notifier
listener_stream_unsubscribe(Context) ->
    Self = self(),
    lists:foreach(fun(Event) -> z_notifier:detach(Event, Self, Context) end, ?UPDATES_LISTENER_EVENTS_LIST).


rerender_job_list(Context) ->
    Target   = "div_job_list",
    Template = "_admin_cron_job_list.tpl",
    Context1 = z_render:wire({update, [{target, Target}, {template, Template}]}, Context),
    z_session_page:add_script(Context1).
