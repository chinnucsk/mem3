%%% membership module
%%%
%%% State of the gen_server is a #mem record
%%%
%%% Nodes and Gossip are the same thing, and are a list of three-tuples like:
%%%
%%%  [ {Pos,NodeName,Options} | _ ]
%%%
%%%  Position is 1-based incrementing in order of node joining
%%%
%%%  Options is a proplist, with [{hints, [Part1|_]}] denoting that the node
%%%   is responsible for the extra partitions too.
%%%
%%% TODO: dialyzer type specs
%%%
-module(mem3_server).
-author('brad@cloudant.com').

-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, stop/0, stop/1, reset/0]).
-export([join/3, clock/0, state/0, states/0, nodes/0, fullnodes/0,
         start_gossip/0]).

%% for testing more than anything else
-export([merge_nodes/2, next_up_node/1, next_up_node/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% includes
-include("mem3.hrl").

-define(SERVER, membership).
-define(STATE_FILE_PREFIX, "membership").


%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link([]).


-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).


-spec stop() -> ok.
stop() ->
    stop(?MODULE).


-spec stop(atom()) -> ok.
stop(Server) ->
    gen_server:cast(Server, stop).


-spec join(join_type(), mem_node_list() | {node(), options()}, node() | nil) ->
    ok.
join(JoinType, Payload, PingNode) ->
    gen_server:call(?SERVER, {join, JoinType, Payload, PingNode}).


-spec clock() -> vector_clock().
clock() ->
    gen_server:call(?SERVER, clock).


-spec state() -> mem_state().
state() ->
    gen_server:call(?SERVER, state).


%% @doc Detailed report of cluster-wide membership state.  Queries the state
%%      on all member nodes and builds a dictionary with unique states as the
%%      key and the nodes holding that state as the value.  Also reports member
%%      nodes which fail to respond and nodes which are connected but are not
%%      cluster members.  Useful for debugging.
-spec states() -> [{mem_state() | bad_nodes | non_member_nodes, [node()]}].
states() ->
    {ok, Nodes} = mem3:nodes(),
    AllNodes = [node()|erlang:nodes()],
    {Replies, BadNodes} = gen_server:multi_call(Nodes, ?SERVER, state),
    Dict = lists:foldl(fun({Node, {ok,State}}, D) ->
        orddict:append(State, Node, D)
    end, orddict:new(), Replies),
    [{non_member_nodes, AllNodes -- Nodes}, {bad_nodes, BadNodes} | Dict].

-spec start_gossip() -> ok.
start_gossip() ->
    gen_server:call(?SERVER, start_gossip).


-spec reset() -> ok | not_reset.
reset() ->
    gen_server:call(?SERVER, reset).


%% @doc get the list of cluster nodes (according to membership module)
%%      This may differ from erlang:nodes()
%%      Guaranteed to be in order of State's node list (1st elem in 3-tuple)
-spec nodes() -> {ok, [node()]}.
nodes() ->
  gen_server:call(?SERVER, nodes).


%% @doc get the list of cluster nodes (according to membership module)
%%      This may differ from erlang:nodes()
%%      Guaranteed to be in order of State's node list (1st elem in 3-tuple)
-spec fullnodes() -> {ok, [mem_node()]}.
fullnodes() ->
  gen_server:call(?SERVER, fullnodes).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% start up membership server
-spec init(args()) -> {ok, mem_state()}.
init(Args) ->
    process_flag(trap_exit,true),
    Test = get_test(Args),
    OldState = read_latest_state_file(Test),
    showroom_log:message(info, "membership: membership server starting...", []),
    net_kernel:monitor_nodes(true),
    State = handle_init(Test, OldState),
    {ok, State#mem{args=Args}}.


%% new node(s) joining to this node
handle_call({join, JoinType, ExtNodes, PingNode}, _From, State) ->
     try
         case handle_join(JoinType, ExtNodes, PingNode, State) of
         {ok, NewState} -> {reply, ok, NewState};
         Other -> {reply, Other, State}
         end
     catch _:Error ->
         showroom_log:message(error, "~p", [Error]),
         {reply, Error, State}
     end;

%% clock
handle_call(clock, _From, #mem{clock=Clock} = State) ->
    {reply, {ok, Clock}, State};

%% state
handle_call(state, _From, State) ->
    {reply, {ok, State}, State};

%% reset - but only if we're in test mode
handle_call(reset, _From, #mem{args=Args} = State) ->
    Test = get_test(Args),
    case Test of
    undefined -> {reply, not_reset, State};
    _ -> {reply, ok, int_reset(Test, State)}
    end;

%% nodes
handle_call(nodes, _From, #mem{nodes=Nodes} = State) ->
    {_,NodeList,_} = lists:unzip3(lists:keysort(1, Nodes)),
    {reply, {ok, NodeList}, State};

%% fullnodes
handle_call(fullnodes, _From, #mem{nodes=Nodes} = State) ->
    {reply, {ok, Nodes}, State};

%% gossip
handle_call({gossip, RemoteState}, {Pid,_Tag} = From, LocalState) ->
    showroom_log:message(info, "membership: received gossip from ~p",
                         [erlang:node(Pid)]),
    handle_gossip(From, RemoteState, LocalState);

% start_gossip
handle_call(start_gossip, _From, State) ->
    NewState = gossip(State),
    {reply, ok, NewState};

%% ignored call
handle_call(Msg, _From, State) ->
    showroom_log:message(info, "membership: ignored call: ~p", [Msg]),
    {reply, ignored, State}.


%% gossip
handle_cast({gossip, RemoteState}, LocalState) ->
    State = case handle_gossip(none, RemoteState, LocalState) of
    {reply, ok, NewState} -> NewState;
    {reply, {new_state, NewState}, _} -> NewState;
    {noreply, NewState} -> NewState
    end,
    {noreply, State};

%% stop
handle_cast(stop, State) ->
    {stop, normal, State};

%% ignored cast
handle_cast(Msg, State) ->
    showroom_log:message(info, "membership: ignored cast: ~p", [Msg]),
    {noreply, State}.


%% @doc handle nodedown messages because we have
%%      net_kernel:monitor_nodes(true)
handle_info({nodedown, Node}, State) ->
    showroom_log:message(alert, "membership: nodedown ~p", [Node]),
    notify(nodedown, [Node], State),
    {noreply, State};

%% @doc handle nodeup messages because we have
%%      net_kernel:monitor_nodes(true)
handle_info({nodeup, Node}, State) ->
    showroom_log:message(alert, "membership: nodeup   ~p", [Node]),
    notify(nodeup, [Node], State),
    gossip_cast(State),
    {noreply, State};

%% ignored info
handle_info(Info, State) ->
    showroom_log:message(info, "membership: ignored info: ~p", [Info]),
    {noreply, State}.


% terminate
terminate(_Reason, _State) ->
    ok.


% ignored code change
code_change(OldVsn, State, _Extra) ->
    io:format("Unknown Old Version~nOldVsn: ~p~nState : ~p~n", [OldVsn, State]),
    {ok, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc if Args has config use it, otherwise call configuration module
%%      most times Args will have config during testing runs
%get_config(Args) ->
%    case proplists:get_value(config, Args) of
%    undefined -> configuration:get_config();
%    Any -> Any
%    end.


get_test(Args) ->
    proplists:get_value(test, Args).


%% @doc handle_init starts a node
%%      Most of the time, this puts the node in a single-node cluster setup,
%%      But, we could be automatically rejoining a cluster after some downtime.
%%      See handle_join for initing, joining, leaving a cluster, or replacing a
%%      node.
%% @end
handle_init(Test, nil) ->
    int_reset(Test);

handle_init(_Test, #mem{nodes=Nodes, args=Args} = OldState) ->
    % there's an old state, let's try to rejoin automatically
    %  but only if we can compare our old state to other available
    %  nodes and get a match... otherwise get a human involved
    {_, NodeList, _} = lists:unzip3(Nodes),
    ping_all_yall(NodeList),
    {RemoteStates, _BadNodes} = get_remote_states(NodeList),
    Test = get_test(Args),
    case compare_state_with_rest(OldState, RemoteStates) of
    match ->
        showroom_log:message(info, "membership: rejoined successfully", []),
        OldState;
    Other ->
        showroom_log:message(error, "membership: rejoin failed: ~p", [Other]),
        int_reset(Test)
    end.


%% @doc handle join activities, return {ok,NewState}
-spec handle_join(join_type(), [mem_node()], ping_node(), mem_state()) ->
             {ok, mem_state()}.
% init
handle_join(init, ExtNodes, nil, State) ->
    {_,Nodes,_} = lists:unzip3(ExtNodes),
    ping_all_yall(Nodes),
    int_join(ExtNodes, State);
% join
handle_join(join, ExtNodes, PingNode, #mem{args=Args} = State) ->
    NewState = case get_test(Args) of
    undefined -> get_pingnode_state(PingNode);
    _ -> State % testing, so meh
    end,
    % now use this info to join the ring
    int_join(ExtNodes, NewState);
% replace
handle_join(replace, OldNode, PingNode, State) when is_atom(OldNode) ->
    handle_join(replace, {OldNode, []}, PingNode, State);
handle_join(replace, [OldNode | _], PingNode, State) ->
    handle_join(replace, {OldNode, []}, PingNode, State);
handle_join(replace, {OldNode, NewOpts}, PingNode, State) ->
    OldState = #mem{nodes=OldNodes} = get_pingnode_state(PingNode),
    {Order, OldNode, _OldOpts} = lists:keyfind(OldNode, 2, OldNodes),
    NewNodes = lists:keyreplace(OldNode, 2, OldNodes, {Order, node(), NewOpts}),
    notify(node_leave, [OldNode], State),
    int_join([], OldState#mem{nodes=NewNodes});
% leave
handle_join(leave, [OldNode | _], _PingNode, State) ->
    % TODO implement me
    notify(node_leave, [OldNode], State),
    ok;

handle_join(JoinType, _, PingNode, _) ->
    showroom_log:message(info, "membership: unknown join type: ~p "
                         "for ping node: ~p", [JoinType, PingNode]),
    {error, unknown_join_type}.

%% @doc common operations for all join types
int_join(ExtNodes, #mem{nodes=Nodes, clock=Clock} = State) ->
    NewNodes = lists:foldl(fun({Pos, N, _Options}=New, AccIn) ->
        check_pos(Pos, N, Nodes),
        notify(node_join, [N], State),
        [New|AccIn]
    end, Nodes, ExtNodes),
    NewNodes1 = lists:sort(NewNodes),
    NewClock = vector_clock:increment(node(), Clock),
    NewState = State#mem{nodes=NewNodes1, clock=NewClock},
    install_new_state(NewState),
    {ok, NewState}.


install_new_state(#mem{args=Args} = State) ->
    Test = get_test(Args),
    save_state_file(Test, State),
    gossip(call, Test, State).


get_pingnode_state(PingNode) ->
    {ok, RemoteState} = gen_server:call({?SERVER, PingNode}, state),
    RemoteState.


%% @doc handle the gossip messages
%%      We're not using vector_clock:resolve b/c we need custom merge strategy
handle_gossip(From, RemoteState=#mem{clock=RemoteClock},
              LocalState=#mem{clock=LocalClock}) ->
    case vector_clock:compare(RemoteClock, LocalClock) of
    equal ->
        {reply, ok, LocalState};
    less ->
        % remote node needs updating
        {reply, {new_state, LocalState}, LocalState};
    greater when From == none->
        {noreply, install_new_state(RemoteState)};
    greater ->
        % local node needs updating
        gen_server:reply(From, ok), % reply to sender first
        {noreply, install_new_state(RemoteState)};
    concurrent ->
        % ick, so let's resolve and merge states
        showroom_log:message(info,
            "membership: Concurrent Clocks~n"
            "RemoteState : ~p~nLocalState : ~p~n"
            , [RemoteState, LocalState]),
        MergedState = merge_states(RemoteState, LocalState),
        if From =/= none ->
            % reply to sender
            gen_server:reply(From, {new_state, MergedState})
        end,
        {noreply, install_new_state(MergedState)}
    end.


merge_states(#mem{clock=RemoteClock, nodes=RemoteNodes} = _RemoteState,
             #mem{clock=LocalClock, nodes=LocalNodes} = LocalState) ->
    MergedClock = vector_clock:merge(RemoteClock, LocalClock),
    MergedNodes = merge_nodes(RemoteNodes, LocalNodes),
    LocalState#mem{clock=MergedClock, nodes=MergedNodes}.


%% this will give one of the lists back, deterministically
merge_nodes(Remote, Local) ->
    % get rid of the initial 0 node if it's still there, and sort
    Remote1 = lists:usort(lists:keydelete(0,1,Remote)),
    Local1 = lists:usort(lists:keydelete(0,1,Local)),
    % handle empty lists as well as other cases
    case {Remote1, Local1} of
    {[], L} -> L;
    {R, []} -> R;
    _ -> erlang:min(Remote1, Local1)
    end.


gossip(#mem{args=Args} = NewState) ->
    Test = get_test(Args),
    gossip(call, Test, NewState).


gossip_cast(#mem{nodes=[]}) -> ok;
gossip_cast(#mem{args=Args} = NewState) ->
    Test = get_test(Args),
    gossip(cast, Test, NewState).


-spec gossip(gossip_fun(), test(), mem_state()) -> mem_state().
gossip(_, _, #mem{nodes=[]}) -> ok;
gossip(Fun, undefined, #mem{nodes=StateNodes} = State) ->
    {_, Nodes, _} = lists:unzip3(StateNodes),
    case next_up_node(Nodes) of
    no_gossip_targets_available ->
        State; % skip gossip, I'm the only node
    TargetNode ->
        showroom_log:message(info, "membership: firing gossip from ~p to ~p",
            [node(), TargetNode]),
        case gen_server:Fun({?SERVER, TargetNode}, {gossip, State}) of
        ok -> State;
        {new_state, NewState} -> NewState;
        Error -> throw({unknown_gossip_response, Error})
        end
    end;

gossip(_,_,_) ->
    % testing, so don't gossip
    ok.


next_up_node(Nodes) ->
    next_up_node(node(), Nodes, up_nodes()).


next_up_node(Node, Nodes, UpNodes) ->
    {A, [Node|B]} = lists:splitwith(fun(N) -> N /= Node end, Nodes),
    List = lists:append(B, A), % be sure to eliminate Node
    DownNodes = Nodes -- UpNodes,
    case List -- DownNodes of
    [Target|_] -> Target;
    [] -> no_gossip_targets_available
    end.


up_nodes() ->
    % TODO: implement cache (fb 9704 & 9449)
    erlang:nodes().


%% @doc find the latest state file on disk
find_latest_state_filename() ->
    Dir = couch_config:get("couchdb", "database_dir"),
    case file:list_dir(Dir) of
    {ok, Filenames} ->
        Timestamps = [list_to_integer(TS) || {?STATE_FILE_PREFIX, TS} <-
           [list_to_tuple(string:tokens(FN, ".")) || FN <- Filenames]],
        SortedTimestamps = lists:reverse(lists:sort(Timestamps)),
        case SortedTimestamps of
        [Latest | _] ->
            {ok, Dir ++ "/" ++ ?STATE_FILE_PREFIX ++ "." ++
             integer_to_list(Latest)};
        _ ->
            throw({error, mem_state_file_not_found})
        end;
    {error, Reason} ->
        throw({error, Reason})
    end.


%% (Test, Config)
read_latest_state_file(undefined) ->
    try
        {ok, File} = find_latest_state_filename(),
        case file:consult(File) of
        {ok, [#mem{}=State]} -> State;
        _Else ->
                throw({error, bad_mem_state_file})
        end
    catch _:Error ->
        showroom_log:message(info, "membership: ~p", [Error]),
        nil
    end;
read_latest_state_file(_) ->
    nil.


%% @doc save the state file to disk, with current timestamp.
%%      thx to riak_ring_manager:do_write_ringfile/1
-spec save_state_file(test(), mem_state()) -> ok.
save_state_file(undefined, State) ->
    Dir = couch_config:get("couchdb", "database_dir"),
    {{Year, Month, Day},{Hour, Minute, Second}} = calendar:universal_time(),
    TS = io_lib:format("~B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B",
                       [Year, Month, Day, Hour, Minute, Second]),
    FN = Dir ++ "/" ++ ?STATE_FILE_PREFIX ++ "." ++ TS,
    ok = filelib:ensure_dir(FN),
    {ok, File} = file:open(FN, [binary, write]),
    io:format(File, "~w.~n", [State]),
    file:close(File);

save_state_file(_,_) -> ok. % don't save if testing


check_pos(Pos, Node, Nodes) ->
    Found = lists:keyfind(Pos, 1, Nodes),
    case Found of
    false -> ok;
    _ ->
        {_,OldNode,_} = Found,
        if
        OldNode =:= Node ->
            Msg = "node_exists_at_position_" ++ integer_to_list(Pos),
            throw({error, list_to_binary(Msg)});
        true ->
            Msg = "position_exists_" ++ integer_to_list(Pos),
            throw({error, list_to_binary(Msg)})
        end
    end.


int_reset(Test) ->
    int_reset(Test, #mem{}).


int_reset(_Test, State) ->
    State#mem{nodes=[], clock=[]}.


ping_all_yall(Nodes) ->
    lists:foreach(fun(Node) ->
        net_adm:ping(Node)
    end, Nodes),
    timer:sleep(500). % sigh.


get_remote_states(NodeList) ->
    NodeList1 = lists:delete(node(), NodeList),
    {States1, BadNodes} = rpc:multicall(NodeList1, mem3, state, [], 5000),
    {_Status, States2} = lists:unzip(States1),
    NodeList2 = NodeList1 -- BadNodes,
    {lists:zip(NodeList2,States2), BadNodes}.


%% @doc compare state with states based on vector clock
%%      return match | {bad_state_match, Node, NodesThatDontMatch}
compare_state_with_rest(#mem{clock=Clock} = _State, States) ->
    Results = lists:map(fun({Node, #mem{clock=Clock1}}) ->
        {vector_clock:equals(Clock, Clock1), Node}
    end, States),
    BadResults = lists:foldl(fun({true, _N}, AccIn) -> AccIn;
                                ({false, N}, AccIn) -> [N | AccIn]
    end, [], Results),
    if
    length(BadResults) == 0 -> match;
    true -> {bad_state_match, node(), BadResults}
    end.

notify(Type, Nodes, #mem{nodes=MemNodesList} = _State) ->
    {_,MemNodes,_} = lists:unzip3(lists:keysort(1, MemNodesList)),
    lists:foreach(fun(Node) ->
        case lists:member(Node, MemNodes) orelse Type == nodedown of
        true ->
            gen_event:notify(membership_events, {Type, Node});
        _ -> ok % node not in cluster
        end
    end, Nodes).