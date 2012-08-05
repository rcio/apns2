%%%-------------------------------------------------------------------
%%% File    : apns_scheduler.erl
%%% Author  : Wang fei <fei.wang@jimii.cn>
%%% Description : 
%%%
%%% Created : Wang fei <fei.wang@jimii.cn>
%%%-------------------------------------------------------------------
-module(apns_scheduler).

-include("apns.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([send_message/3, send_message_failed/1, done_working/1, stop_working/1]).

-export([save_message/1, get_first_message/0]).

-record(state, {plist = [],
	       current_p_count = 0,
	       max_p_count = 100,
	       running = true,
	       connection = #apns_connection{}}).

-define(SERVER, ?MODULE).
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

send_message(Alert, Badge, DeviceToken) ->
    gen_server:cast(?MODULE, {send_message, #apns_msg{alert  = Alert,
						      badge  = Badge,
						      sound  = "chime",
						      device_token = DeviceToken}}).

send_message_failed(Msg) ->
    gen_server:call(?MODULE, {send_message_failed, Msg}).

done_working(Pid) ->
    %% dead loop
    receive 
	after 100 ->
		ture
	end,
    gen_server:cast(?MODULE, {done_working, Pid}).

stop_working(Pid) ->
    gen_server:cast(?MODULE, {stop_working, Pid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    mnesia:create_table(apns_msg, [{attributes, record_info(fields, apns_msg)},
				     {type, ordered_set},
				     {disc_copies, [node()]}]),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({send_message_failed, Msg}, _From, State = #state{plist = []}) ->
    save_message(Msg),
    {reply, ok, State};

handle_call({send_message_failed, Msg}, _From, State = #state{plist = [Pid|T]}) ->
    apns_connection:send_message(Pid, Msg),
    {reply, ok, State#state{plist = T}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({send_message, Msg}, State = #state{plist = [], current_p_count = Current, max_p_count = Max, connection = Connection}) ->
    error_logger:info_msg("current ~p, max ~p ~p~n", [Current, Max, State]),
    case Current < Max of
	true ->
	    case send_message_via_new_connection(Msg, Connection) of
		true ->
		    {noreply, State#state{current_p_count = Current + 1}};
		_ ->
		    save_message(Msg),
		    {noreply, State}
	    end;
	false ->
	    save_message(Msg),
	    {noreply, State}
    end;

handle_cast({send_message, Msg}, #state{plist = [Pid|T]}) ->
    apns_connection:send_message(Pid, Msg),
    {noreply, #state{plist = T}};

handle_cast({done_working, Pid}, State) ->
    case get_first_message() of
	[] ->
	    {noreply, #state{plist = lists:append(State#state.plist, [Pid])}};
	[Msg|_T] when is_record(Msg, apns_msg) ->
	    mnesia:dirty_delete_object(Msg),
	    apns_connection:send_message(Pid, Msg),
	    {noreply, State}
    end;

handle_cast({stop_working, Pid}, State = #state{plist = Plist, running = _Running}) ->
    New = lists:delete(Pid, Plist),
    {noreply, State#state{plist = New}};
    
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
save_message(Msg) when is_record(Msg, apns_msg) ->
    mnesia:dirty_write(Msg).

get_first_message() ->
    Key = mnesia:dirty_first(apns_msg),
    Msg = mnesia:dirty_read({apns_msg, Key}),
    case Msg of
	ResList when is_list(ResList) ->
	    ResList;
	_ ->
	    []
    end.

send_message_via_new_connection(Msg, Connection) ->
    case connect(Connection) of
	{ok, Pid} ->
	    apns_connection:send_message(Pid, Msg),
	    true;
	Error ->
	    error_logger:error_msg("Create new conection porcess error ~p", [Error]),
	    false
    end.

connect(Connection) ->
    apns_ssl_sup:start_connection(Connection).
