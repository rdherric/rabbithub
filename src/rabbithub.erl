-module(rabbithub).
-behaviour(application).

-export([start/2, stop/1]).
-export([setup_schema/0]).
-export([instance_key/0, sign_term/1, verify_term/1]).
-export([b64enc/1, b64dec/1]).
-export([canonical_scheme/0, canonical_host/0, canonical_basepath/0]).
-export([default_username/0]).
-export([r/3,r/2]).
-export([respond_xml/5]).
-export([deliver_via_post/3, error_and_unsub/2]).

-export([init/1]).

%% Start subscriptions via a bootstep only once routing is ready. Schema might
%% already be set up, which is fine.
-rabbit_boot_step({?MODULE,
                   [{description, "RabbitHub"},
                    {mfa, {rabbithub, setup_schema, []}},
                    {mfa, {rabbit_sup, start_child, [rabbithub_sup]}},
                    {mfa, {rabbithub_subscription, start_subscriptions, []}},
                    {requires, routing_ready}]}).

-include_lib("xmerl/include/xmerl.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include("rabbithub.hrl").


start(_Type, _StartArgs) ->
    hub_init(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) -> {ok, {{one_for_one, 1, 5}, []}}.

hub_init() ->
    setup_schema(),
    ssl:start(),

    %% Sort out HTTP client options
    HttpOpts =  get_env(http_client_options, []), 
    ok = httpc:set_options(HttpOpts),
    {ok, Opts} = httpc:get_options(all),
    rabbithub_web:start().


stop(_State) ->
    ok.

setup_schema() ->
    ok = create_table(rabbithub_lease,
                      [{attributes, record_info(fields, rabbithub_lease)},
                       {disc_copies, [node()]}]),
    ok = create_table(rabbithub_subscription_pid,
                      [{attributes, record_info(fields, rabbithub_subscription_pid)}]),
    ok = mnesia:wait_for_tables([rabbithub_lease,
                                 rabbithub_subscription_pid],
                                5000),
    ok.

create_table(Name, Params) ->
    case mnesia:create_table(Name, Params) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ok
    end.

get_env(EnvVar, DefaultValue) ->
    case application:get_env(rabbithub, EnvVar) of
        undefined ->
            DefaultValue;
        {ok, V} ->
            V
    end.

instance_key() ->
    case application:get_env(rabbithub, instance_key) of
        undefined ->
            KeyBin = crypto:sha(term_to_binary({node(),
                                                now(),
                                                rabbit_guid:binary(rabbit_guid:gen(), "keyseed")})),
            application:set_env(rabbithub, instance_key, KeyBin),
            KeyBin;
        {ok, KeyBin} ->
            KeyBin
    end.

-record(signed_term_v1, {timestamp, nonce, term}).

sign_term(Term) ->
    Message = #signed_term_v1{timestamp = now(),
                              nonce = rabbit_guid:binary(rabbit_guid:gen(), "nonce"),
                              term = Term},
    DataBlock = zlib:zip(term_to_binary(Message)),
    Mac = crypto:sha_mac(instance_key(), DataBlock),
    20 = size(Mac), %% assertion
    <<Mac/binary, DataBlock/binary>>.

verify_term(Packet) ->
    case catch verify_term1(Packet) of
        {'EXIT', _Reason} -> {error, validation_crashed};
        Other -> Other
    end.

max_age_seconds() -> get_env(signed_term_max_age_seconds, 300).

verify_term1(<<Mac:20/binary, DataBlock/binary>>) ->
    case crypto:sha_mac(instance_key(), DataBlock) of
        Mac ->
            #signed_term_v1{timestamp = Timestamp,
                            nonce = _Nonce,
                            term = Term}
                = binary_to_term(zlib:unzip(DataBlock)),
            AgeSeconds = timer:now_diff(now(), Timestamp) div 1000000,
            TooOld = max_age_seconds(),
            if
                AgeSeconds >= TooOld ->
                    {error, expired};
                true ->
                    {ok, Term}
            end;
        _ ->
            {error, validation_failed}
    end.

%% URL-safe variant of Base64 encoding.
b64enc(IoList) ->
    S = base64:encode_to_string(IoList),
    to_urlsafe([], S).

to_urlsafe(Acc, []) ->
    lists:reverse(Acc);
to_urlsafe(Acc, [$+ | Rest]) ->
    to_urlsafe([$- | Acc], Rest);
to_urlsafe(Acc, [$/ | Rest]) ->
    to_urlsafe([$_ | Acc], Rest);
to_urlsafe(Acc, [$= | Rest]) ->
    to_urlsafe(Acc, Rest);
to_urlsafe(Acc, [C | Rest]) ->
    to_urlsafe([C | Acc], Rest).

%% URL-safe variant of Base64 decoding.
b64dec(Str) ->
    S = from_urlsafe([], 0, Str),
    base64:decode(S).

from_urlsafe(Acc, N, []) ->
    lists:reverse(case N rem 4 of
                      0 -> Acc;
                      1 -> exit({invalid_b64_length, N});
                      2 -> "==" ++ Acc;
                      3 -> "=" ++ Acc
                  end);
from_urlsafe(Acc, N, [$- | Rest]) ->
    from_urlsafe([$+ | Acc], N + 1, Rest);
from_urlsafe(Acc, N, [$_ | Rest]) ->
    from_urlsafe([$/ | Acc], N + 1, Rest);
from_urlsafe(Acc, N, [C | Rest]) ->
    from_urlsafe([C | Acc], N + 1, Rest).

canonical_scheme() -> get_env(canonical_scheme, "http").
canonical_host() -> get_env(canonical_host, "localhost").
canonical_basepath() -> get_env(canonical_basepath, "rabbithub").

default_username() -> get_env(default_username, undefined).

r(ResourceType, ResourceName) when is_list(ResourceName) ->
    r(ResourceType, list_to_binary(ResourceName));
r(ResourceType, ResourceName) ->
    rabbit_misc:r(<<"/">>, ResourceType, ResourceName).

%% BRC (want to make vhost variable)
r(VHost, ResourceType, ResourceName) when is_list(ResourceName) ->
    r(VHost, ResourceType, list_to_binary(ResourceName));
r(VHost, ResourceType, ResourceName) ->
    rabbit_misc:r(VHost, ResourceType, ResourceName).

respond_xml(Req, StatusCode, Headers, StylesheetRelUrlOrNone, XmlElement) ->
    Req:respond({StatusCode,
                 [{"Content-type", "text/xml"}] ++ Headers,
                 "<?xml version=\"1.0\"?>" ++
                   stylesheet_pi(StylesheetRelUrlOrNone) ++
                   xmerl:export_simple([XmlElement],
                                       xmerl_xml,
                                       [#xmlAttribute{name=prolog, value=""}])}).

stylesheet_pi(none) ->
    [];
stylesheet_pi(RelUrl) ->
    ["<?xml-stylesheet href=\"", RelUrl, "\" type=\"text/xsl\" ?>"].

deliver_via_post(#rabbithub_subscription{callback = Callback},
                 #basic_message{routing_keys = [RoutingKeyBin | _],
                                content = Content0 = #content{payload_fragments_rev = PayloadRev}},
                 ExtraHeaders) ->
    case catch mochiweb_util:urlsplit(Callback) of
        {_Scheme, _NetLoc, _Path, ExistingQuery, _Fragment} ->         
           #content{properties = #'P_basic'{content_type = ContentTypeBin}} =
               rabbit_binary_parser:ensure_content_decoded(Content0),
           PayloadBin = list_to_binary(lists:reverse(PayloadRev)),

           C = case ExistingQuery of
                   "" -> "?";
                   _  -> "&"
               end,

		   % Get the hub.topic part of the URL if the environment variable
		   % indicates that it should be added as the PubSubHubBub specification
		   % does not require it - default is to add the topic
		   Topic = case application:get_env(rabbithub, append_hub_topic_to_callback) of
				{ok, false} ->
					"";
				_ ->
					C ++ mochiweb_util:urlencode([{'hub.topic', RoutingKeyBin}])
		   end,

           URL = Callback ++ Topic,

		   ContentType = case ContentTypeBin of
							undefined -> "application/octet-stream";
							_ -> binary_to_list(ContentTypeBin)
						 end,

		   Payload = {URL, 
					 [{"Content-length", integer_to_list(size(PayloadBin))},
					  {"X-AMQP-Routing-Key", binary_to_list(RoutingKeyBin)} | ExtraHeaders], 
                      ContentType, PayloadBin},
						 
		   % Log the request if the environment variable has been set - default
		   % is not to log the request
		   case application:get_env(rabbithub, log_http_post_request) of
				{ok, true} ->
					rabbit_log:info("RabbitHub post request~n~p~n", [Payload]);
				_ ->
					ok
		   end,
		   
           case httpc:request(post, Payload, [], []) of
               {ok, {{_Version, StatusCode, _StatusText}, _Headers, _Body}} ->
                  if
                     StatusCode >= 200 andalso StatusCode < 300 ->
                         {ok, StatusCode};
                     true ->
                         {error, StatusCode, {{_Version, StatusCode, _StatusText}, _Headers, _Body}}
                  end;
               {error, Reason} ->
                   {error, Reason, {}}
            end;
        _ ->
            {error, invalid_callback_url, {}}
    end.


error_and_unsub(Subscription, ErrorReport) ->
    rabbit_log:error("RabbitHub post error~n~p~n", [ErrorReport]),
	
	% Check the environment variable unsubscribe_on_http_post_error to 
	% determine if the subscription should be deleted or not - default 
	% is to unsubscribe on any post error
	case application:get_env(rabbithub, unsubscribe_on_http_post_error) of
		{ok, false} ->
			ok;
		_ ->
		   rabbithub_subscription:delete(Subscription)
	end,

    ok.
