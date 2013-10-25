%% -*- mode: nitrogen -*-
%% vim: ts=4 sw=4 et
-module(cowboy_simple_bridge_sup).
-behaviour(supervisor).
-include("simple_bridge.hrl").
-export([
    start_link/0,
    init/1
]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    io:format("Calling super~n"),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    application:start(crypto),
    application:start(ranch),
    application:start(cowboy),
    {Address, Port} = simple_bridge_util:get_address_and_port(cowboy),
    Dispatch = generate_dispatch(),

    io:format("Starting Cowboy Server on ~s:~p~n",
              [Address, Port]),

    {ok, _} = cowboy:start_http(http, 100, [{port, Port}], [
        {env, [{dispatch, Dispatch}]},
        {max_keepalive, 50}
    ]),

    {ok, { {one_for_one, 5, 10}, []} }.


%% @doc Generates the dispatch based on the desired environment
%% 1) First it checks if there's a cowboy_dispatch config, if there is, it uses
%%    that.
%% 2) Then it checks for cowboy_dispatch_fun, which is a tuple
%%    {Module,Function} and uses the result of calling Module:Function()
%% 3) Finally, if all else fails, it uses the provided document_root and
%%    static_paths config values standard to simple_bridge to generate a
%%    cowboy-specific dispatch table.
generate_dispatch() ->
    case simple_bridge_util:get_env(cowboy_dispatch) of
        {ok, Dispatch} -> Dispatch;
        undefined ->
            case simple_bridge_util:get_env(cowboy_dispatch_fun) of
                {ok, {M,F}} ->
                    M:F();
                undefined ->
                    build_dispatch()
            end
    end.

%% @doc Gets the environment variables document_root and static_paths, and
%% generates dispatches from them
build_dispatch() ->
    {DocRoot, StaticPaths}= simple_bridge_util:get_docroot_and_static_paths(cowboy),
    io:format("Static Paths: ~p~nDocument Root for Static: ~s~n",
              [StaticPaths, DocRoot]),
    build_dispatch(DocRoot, StaticPaths).

%% @doc Generate the dispatch tables
build_dispatch(DocRoot,StaticPaths) ->
    Handler = cowboy_static,
    StaticDispatches = lists:map(fun(Dir) ->
        Path = reformat_path(Dir),
        Opts = [
                {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
                | localized_dir_file(DocRoot, Dir)
        ],
        {Path,Handler,Opts}
    end,StaticPaths),

    %% HandlerModule will end up calling HandlerModule:handle(Req,HandlerOpts)
    HandlerModule = cowboy_simple_bridge_anchor,
    HandlerOpts = [],

    %% Start Cowboy...
    %% NOTE: According to Loic, there's no way to pass the buck back to cowboy 
    %% to handle static dispatch files so we want to make sure that any large 
    %% files get caught in general by cowboy and are never passed to the nitrogen
    %% handler at all. In general, your best bet is to include the directory in
    %% the static_paths section of cowboy.config
    %%
    %% Simple Bridge will do its best to efficiently handle static files, if
    %% necessary but it's recommended to just make sure you properly use the
    %% static_paths, or rewrite cowboy's dispatch table
    Dispatch = [
        %% Nitrogen will handle everything that's not handled in the StaticDispatches
        {'_', StaticDispatches ++ [{'_',HandlerModule , HandlerOpts}]}
    ],
    cowboy_router:compile(Dispatch).


localized_dir_file(DocRoot,Path) ->
    NewPath = case hd(Path) of
        $/ -> DocRoot ++ Path;
        _ -> DocRoot ++ "/" ++ Path
    end,
    _NewPath2 = case lists:last(Path) of
        $/ -> [{directory, NewPath}];
        _ ->
            Dir = filename:dirname(NewPath),
            File = filename:basename(NewPath),
            [
                {directory,Dir},
                {file,File}
            ]
    end.

%% Ensure the paths start with /, and if a path ends with /, then add "[...]" to it
reformat_path(Path) ->
    Path2 = case hd(Path) of
        $/ -> Path;
        $\ -> Path;
        _ -> [$/|Path]
    end,
    Path3 = case lists:last(Path) of 
        $/ -> Path2 ++ "[...]";
        $\ -> Path2 ++ "[...]";
        _ -> Path2
    end,
    Path3.