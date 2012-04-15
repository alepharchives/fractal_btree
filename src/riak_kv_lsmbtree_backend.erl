%% -------------------------------------------------------------------
%%
%% riak_kv_lsmbtree_backend: LSM-Btree Driver for Riak
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_kv_lsmbtree_backend).
-behavior(lsmbtree_riak_kv_backend).
-author('Steve Vinoski <steve@basho.com>').

%% KV Backend API
-export([api_version/0,
         capabilities/1,
         capabilities/2,
         start/2,
         stop/1,
         get/3,
         put/5,
         delete/4,
         drop/1,
         fold_buckets/4,
         fold_keys/4,
         fold_objects/4,
         is_empty/1,
         status/1,
         callback/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(API_VERSION, 1).
%% TODO: for when this backend supports 2i
%%-define(CAPABILITIES, [async_fold, indexes]).
-define(CAPABILITIES, [async_fold]).

-record(state, {db,
                partition :: integer()}).

-type state() :: #state{}.
-type config() :: [{atom(), term()}].

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Return the major version of the
%% current API.
-spec api_version() -> {ok, integer()}.
api_version() ->
    {ok, ?API_VERSION}.

%% @doc Return the capabilities of the backend.
-spec capabilities(state()) -> {ok, [atom()]}.
capabilities(_) ->
    {ok, ?CAPABILITIES}.

%% @doc Return the capabilities of the backend.
-spec capabilities(riak_object:bucket(), state()) -> {ok, [atom()]}.
capabilities(_, _) ->
    {ok, ?CAPABILITIES}.

%% @doc Start the lsm_btree backend
-spec start(integer(), config()) -> {ok, state()} | {error, term()}.
start(Partition, Config) ->
    %% Get the data root directory
    case app_helper:get_prop_or_env(data_root, Config, lsm_btree) of
        undefined ->
            lager:error("Failed to create lsm_btree dir: data_root is not set"),
            {error, data_root_unset};
        DataRoot ->
            AppStart = case application:start(lsm_btree) of
                           ok ->
                               ok;
                           {error, {already_started, _}} ->
                               ok;
                           {error, Reason} ->
                               lager:error("Failed to start lsm_btree: ~p", [Reason]),
                               {error, Reason}
                       end,
            case AppStart of
                ok ->
                    ok = filelib:ensure_dir(filename:join(DataRoot, "x")),
		    DbName = filename:join(DataRoot, "lb" ++ integer_to_list(Partition)),
                    case lsm_btree:open(DbName) of
                        {ok, Db} ->
			    {ok, #state{db=Db, partition=Partition}};
			{error, OpenReason}=OpenError ->
			    lager:error("Failed to open lsm_btree: ~p\n", [OpenReason]),
			    OpenError
                    end;
                Error ->
                    Error
            end
    end.

%% @doc Stop the lsm_btree backend
-spec stop(state()) -> ok.
stop(#state{db=Db}) ->
    ok = lsm_btree:close(Db).

%% @doc Retrieve an object from the lsm_btree backend
-spec get(riak_object:bucket(), riak_object:key(), state()) ->
                 {ok, any(), state()} |
                 {ok, not_found, state()} |
                 {error, term(), state()}.
get(Bucket, Key, #state{db=Db}=State) ->
    LBKey = to_object_key(Bucket, Key),
    case lsm_btree:lookup(Db, LBKey) of
        {ok, Value} ->
            {ok, Value, State};
        notfound  ->
            {error, not_found, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @doc Insert an object into the lsm_btree backend.
-type index_spec() :: {add, Index, SecondaryKey} | {remove, Index, SecondaryKey}.
-spec put(riak_object:bucket(), riak_object:key(), [index_spec()], binary(), state()) ->
                 {ok, state()} |
                 {error, term(), state()}.
put(Bucket, PrimaryKey, _IndexSpecs, Val, #state{db=Db}=State) ->
    LBKey = to_object_key(Bucket, PrimaryKey),
    ok = lsm_btree:put(Db, LBKey, Val),
    {ok, State}.

%% @doc Delete an object from the lsm_btree backend
-spec delete(riak_object:bucket(), riak_object:key(), [index_spec()], state()) ->
                    {ok, state()} |
                    {error, term(), state()}.
delete(Bucket, Key, _IndexSpecs, #state{db=Db}=State) ->
    LBKey = to_object_key(Bucket, Key),
    case lsm_btree:delete(Db, LBKey) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% @doc Fold over all the buckets
-spec fold_buckets(riak_kv_backend:fold_buckets_fun(),
                   any(),
                   [],
                   state()) -> {ok, any()} | {async, fun()}.
fold_buckets(FoldBucketsFun, Acc, Opts, #state{db=Db}) ->
    FoldFun = fold_buckets_fun(FoldBucketsFun),
    BucketFolder =
        fun() ->
                try
		    lsm_btree:sync_fold_range(Db, FoldFun, {Acc, []}, undefined, undefined)
                catch
                    {break, AccFinal} ->
                        AccFinal
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, BucketFolder};
        false ->
            {ok, BucketFolder()}
    end.

%% @doc Fold over all the keys for one or all buckets.
-spec fold_keys(riak_kv_backend:fold_keys_fun(),
                any(),
                [{atom(), term()}],
                state()) -> {ok, term()} | {async, fun()}.
fold_keys(FoldKeysFun, Acc, Opts, #state{db=Db}) ->
    %% Figure out how we should limit the fold: by bucket, by
    %% secondary index, or neither (fold across everything.)
    Bucket = lists:keyfind(bucket, 1, Opts),
    Index = lists:keyfind(index, 1, Opts),

    %% Multiple limiters may exist. Take the most specific limiter.
    Limiter =
        if Index /= false  -> Index;
           Bucket /= false -> Bucket;
           true            -> undefined
        end,

    %% Set up the fold...
    FoldFun = fold_keys_fun(FoldKeysFun, Limiter),
    KeyFolder =
        fun() ->
                try
		    lsm_btree:sync_fold_range(Db, FoldFun, Acc, undefined, undefined)
                catch
                    {break, AccFinal} ->
                        AccFinal
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, KeyFolder};
        false ->
            {ok, KeyFolder()}
    end.

%% @doc Fold over all the objects for one or all buckets.
-spec fold_objects(riak_kv_backend:fold_objects_fun(),
                   any(),
                   [{atom(), term()}],
                   state()) -> {ok, any()} | {async, fun()}.
fold_objects(FoldObjectsFun, Acc, Opts, #state{db=Db}) ->
    Bucket =  proplists:get_value(bucket, Opts),
    FoldFun = fold_objects_fun(FoldObjectsFun, Bucket),
    ObjectFolder =
        fun() ->
                try
		    lsm_btree:sync_fold_range(Db, FoldFun, Acc, undefined, undefined)
                catch
                    {break, AccFinal} ->
                        AccFinal
                end
        end,
    case lists:member(async_fold, Opts) of
        true ->
            {async, ObjectFolder};
        false ->
            {ok, ObjectFolder()}
    end.

%% @doc Delete all objects from this lsm_btree backend
-spec drop(state()) -> {ok, state()} | {error, term(), state()}.
drop(#state{}=State) ->
    %% TODO: not yet implemented
    {ok, State}.

%% @doc Returns true if this lsm_btree backend contains any
%% non-tombstone values; otherwise returns false.
-spec is_empty(state()) -> boolean().
is_empty(#state{db=Db}) ->
    FoldFun = fun(_K, _V, _Acc) -> throw(ok) end,
    try
	[] =:= lsm_btree:sync_fold_range(Db, FoldFun, [], undefined, undefined)
    catch
	_:ok ->
	    false
    end.

%% @doc Get the status information for this lsm_btree backend
-spec status(state()) -> [{atom(), term()}].
status(#state{}) ->
    %% TODO: not yet implemented
    [].

%% @doc Register an asynchronous callback
-spec callback(reference(), any(), state()) -> {ok, state()}.
callback(_Ref, _Msg, State) ->
    {ok, State}.


%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private
%% Return a function to fold over the buckets on this backend
fold_buckets_fun(FoldBucketsFun) ->
    fun(K, _V, {Acc, LastBucket}) ->
            case from_object_key(K) of
                {LastBucket, _} ->
                    {Acc, LastBucket};
                {Bucket, _} ->
                    {FoldBucketsFun(Bucket, Acc), Bucket};
                _ ->
                    throw({break, Acc})
            end
    end.

%% @private
%% Return a function to fold over keys on this backend
fold_keys_fun(FoldKeysFun, undefined) ->
    %% Fold across everything...
    fun(K, _V, Acc) ->
            case from_object_key(K) of
                {Bucket, Key} ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(FoldKeysFun, {bucket, FilterBucket}) ->
    %% Fold across a specific bucket...
    fun(K, _V, Acc) ->
            case from_object_key(K) of
                {Bucket, Key} when Bucket == FilterBucket ->
                    FoldKeysFun(Bucket, Key, Acc);
                _ ->
                    throw({break, Acc})
            end
    end;
fold_keys_fun(_FoldKeysFun, Other) ->
    throw({unknown_limiter, Other}).

%% @private
%% Return a function to fold over the objects on this backend
fold_objects_fun(FoldObjectsFun, FilterBucket) ->
    fun(Key, Value, Acc) ->
            case from_object_key(Key) of
                {Bucket, Key} when FilterBucket == undefined;
                                   Bucket == FilterBucket ->
                    FoldObjectsFun(Bucket, Key, Value, Acc);
                _ ->
                    throw({break, Acc})
            end
    end.

to_object_key(Bucket, Key) ->
    sext:encode({o, Bucket, Key}).

from_object_key(LKey) ->
    case sext:decode(LKey) of
        {o, Bucket, Key} ->
            {Bucket, Key};
        _ ->
            undefined
    end.

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

simple_test_() ->
    ?assertCmd("rm -rf test/lsmbtree-backend"),
    application:set_env(lsm_btree, data_root, "test/lsmbtree-backend"),
    lsmbtree_riak_kv_backend:standard_test(?MODULE, []).

custom_config_test_() ->
    ?assertCmd("rm -rf test/lsmbtree-backend"),
    application:set_env(lsm_btree, data_root, ""),
    lsmbtree_riak_kv_backend:standard_test(?MODULE, [{data_root, "test/lsmbtree-backend"}]).

-endif.