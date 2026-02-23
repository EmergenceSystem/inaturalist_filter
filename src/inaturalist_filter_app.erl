%%%-------------------------------------------------------------------
%%% @doc iNaturalist taxa search agent.
%%%
%%% Announces capabilities to em_disco on startup and maintains a
%%% memory of Wikipedia URLs already returned so duplicate taxa across
%%% successive queries are filtered out.
%%%
%%% Handler contract: `handle/2' (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: `#{seen => #{binary_url => true}}'.
%%% @end
%%%-------------------------------------------------------------------
-module(inaturalist_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2]).

-define(AUTOCOMPLETE_URL, "https://api.inaturalist.org/v1/taxa/autocomplete").

-define(CAPABILITIES, [
    <<"inaturalist">>,
    <<"biology">>,
    <<"nature">>,
    <<"taxonomy">>,
    <<"species">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(inaturalist_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(inaturalist_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, Rank, MinObs, IconicTaxon} = extract_params(JsonBinary),
    SearchUrl = build_search_url(Value, Rank, IconicTaxon),
    SslOpts   = [{ssl, [{verify, verify_none},
                        {cacerts, public_key:cacerts_get()}]}],
    case httpc:request(get, {SearchUrl, []}, SslOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_results(Body, Value, Timeout, MinObs);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value       = binary_to_list(maps:get(<<"value">>,           Map, <<"">>)),
            Timeout     = parse_int(maps:get(<<"timeout">>,        Map, 10), 10),
            Rank        = binary_to_list(maps:get(<<"rank">>,            Map, <<"">>)),
            MinObs      = parse_int(maps:get(<<"min_observations">>, Map, 0),  0),
            IconicTaxon = binary_to_list(maps:get(<<"iconic_taxon_id">>, Map, <<"">>)),
            {Value, Timeout, Rank, MinObs, IconicTaxon};
        _ ->
            {binary_to_list(JsonBinary), 10, "", 0, ""}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, "", 0, ""}
    end.

parse_int(V, _D) when is_integer(V) -> V;
parse_int(V, D) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> D end;
parse_int(_, D) -> D.

build_search_url(Query, Rank, IconicTaxon) ->
    Params = add_param("iconic_taxon_id", IconicTaxon,
             add_param("rank",            Rank,
             add_param("q",               uri_string:quote(Query), []))),
    case Params of
        [] -> ?AUTOCOMPLETE_URL;
        _  -> ?AUTOCOMPLETE_URL ++ "?" ++ string:join(Params, "&")
    end.

add_param(_Key, "",    Acc) -> Acc;
add_param(Key,  Value, Acc) -> [Key ++ "=" ++ Value | Acc].

parse_results(JsonData, SearchValue, TimeoutSecs, MinObs) ->
    try json:decode(JsonData) of
        #{<<"results">> := Results} when is_list(Results) ->
            StartTime = erlang:system_time(second),
            process_taxa(Results, SearchValue, StartTime, TimeoutSecs, MinObs, []);
        _ -> []
    catch
        _:_ -> []
    end.

process_taxa([], _Value, _Start, _Timeout, _MinObs, Acc) ->
    lists:reverse(Acc);
process_taxa([Taxon | Rest], Value, Start, Timeout, MinObs, Acc) ->
    case erlang:system_time(second) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = case build_embryo(Taxon, Value, MinObs) of
                {ok, E} -> [E | Acc];
                skip    -> Acc
            end,
            process_taxa(Rest, Value, Start, Timeout, MinObs, NewAcc)
    end.

build_embryo(Taxon, SearchValue, MinObs) ->
    Name        = safe_str(maps:get(<<"name">>,                  Taxon, <<"">>)),
    CommonName  = safe_str(maps:get(<<"preferred_common_name">>, Taxon, <<"">>)),
    Rank        = safe_str(maps:get(<<"rank">>,                  Taxon, <<"">>)),
    ObsCount    = maps:get(<<"observations_count">>,             Taxon, 0),
    WikiUrl     = safe_str(maps:get(<<"wikipedia_url">>,         Taxon, <<"">>)),
    IconicTaxon = safe_str(maps:get(<<"iconic_taxon_name">>,     Taxon, <<"">>)),
    PhotoUrl    = case maps:get(<<"default_photo">>, Taxon, #{}) of
        P when is_map(P) -> safe_str(maps:get(<<"medium_url">>, P, <<"">>));
        _                -> ""
    end,
    case ObsCount >= MinObs andalso search_matches(SearchValue, Name, CommonName) of
        false -> skip;
        true  ->
            Resume = build_resume(Name, CommonName, Rank, ObsCount, IconicTaxon),
            {ok, #{
                <<"properties">> => #{
                    <<"url">>                => list_to_binary(WikiUrl),
                    <<"resume">>             => list_to_binary(Resume),
                    <<"photo_url">>          => list_to_binary(PhotoUrl),
                    <<"scientific_name">>    => list_to_binary(Name),
                    <<"common_name">>        => list_to_binary(CommonName),
                    <<"rank">>               => list_to_binary(Rank),
                    <<"observations_count">> => ObsCount,
                    <<"iconic_taxon">>       => list_to_binary(IconicTaxon)
                }
            }}
    end.

search_matches("", _Name, _Common) -> true;
search_matches(Query, Name, Common) ->
    Low = string:to_lower(Query),
    string:str(string:to_lower(Name),   Low) > 0 orelse
    string:str(string:to_lower(Common), Low) > 0.

build_resume(Name, CommonName, Rank, ObsCount, IconicTaxon) ->
    Common  = case CommonName of "" -> ""; N -> " (" ++ N ++ ")" end,
    CapRank = case Rank of
        ""      -> "";
        [H | T] -> [string:to_upper(H) | string:to_lower(T)]
    end,
    lists:concat([Name, Common, " - ", CapRank,
                  " - ", integer_to_list(ObsCount), " observations",
                  " - ", IconicTaxon]).

safe_str(null)                -> "";
safe_str(undefined)           -> "";
safe_str(<<>>)                -> "";
safe_str(B) when is_binary(B) -> binary_to_list(B);
safe_str(_)                   -> "".

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
