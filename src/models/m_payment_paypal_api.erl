%% @copyright 2026 Marc Worrell
%% @doc API interface and status handling for PayPal PSP.
%% @end

%% Copyright 2026 Marc Worrell
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

-module(m_payment_paypal_api).

-export([
    create/2,
    amount_string/2,

    payment_url/2,

    cancel_payment/3,
    mark_order_cancelled/2,
    capture_order/2,
    sync_order_status/2,

    fetch_order/2,
    webhook_event/2,
    is_valid_webhook_signature/2,

    credentials/1
]).

-export([
    ping/1,
    test/1
]).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_mod_payment/include/payment.hrl").

-define(TIMEOUT_REQUEST, 10000).
-define(TIMEOUT_CONNECT, 5000).
-define(CANCEL_STATE_EXPIRY_HOURS, 72).


% Per https://developer.paypal.com/serversdk/java/api-endpoints/orders/get-order/ is the
% order id size between 1 and 36 chars, inclusive.  Accept a bit more to be future proof.
-define(MAX_ORDERID_SIZE, 40).
-define(MIN_ORDERID_SIZE, 1).

%% @doc Check if the configured PayPal credentials can fetch an OAuth token.
-spec ping(Context) -> ok | {error, term()}
    when Context :: z:context().
ping(Context) ->
    case access_token(Context) of
        {ok, _Token} ->
            ok;
        {error, _} = Error ->
            Error
    end.

test(Context) ->
    PaymentRequest = #payment_request{
        key = undefined,
        user_id = undefined,
        amount = 1.0,
        currency = <<"EUR">>,
        language = z_context:language(Context),
        description_html = <<"Test">>,
        is_qargs = false,
        is_recurring_start = false,
        extra_props = [
            {email, <<"marc@worrell.nl">>},
            {name_surname, <<"Pietersen">>}
        ],
        preferred_psp_module = mod_payment_paypal
    },
    case z_notifier:first(PaymentRequest, Context) of
        #payment_request_redirect{ redirect_uri = RedirectUri } ->
            {ok, RedirectUri};
        Other ->
            Other
    end.

%% @doc Create a new PayPal order.
create(PaymentNr, Context) ->
    {ok, Payment} = m_payment:get(PaymentNr, Context),
    PaymentId = maps:get(<<"id">>, Payment),

    % For now, do not support recurring payments.
    false = maps:get(<<"is_recurring_start">>, Payment),

    Payload = order_payload(Payment, Context),
    case api_call(post, "/v2/checkout/orders", Payload, Context) of
        {ok, #{ <<"id">> := OrderId } = Order} ->
            case approve_url(Order) of
                {ok, ApprovalUrl} ->
                    m_payment_log:log(
                        PaymentId,
                        <<"CREATED">>,
                        [
                            {psp_module, mod_payment_paypal},
                            {psp_external_log_id, OrderId},
                            {description, <<"Created PayPal order ", OrderId/binary>>},
                            {request_result, Order}
                        ],
                        Context),
                    {ok, #payment_psp_handler{
                        psp_module = mod_payment_paypal,
                        psp_external_id = OrderId,
                        psp_data = Order,
                        redirect_uri = ApprovalUrl
                    }};
                {error, _} = Error ->
                    log_create_error(PaymentId, Payload, Order, Context),
                    Error
            end;
        {ok, JSON} ->
            log_create_error(PaymentId, Payload, JSON, Context),
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"API error creating PayPal order: unexpected JSON">>,
                result => error,
                reason => json,
                payment_id => PaymentId,
                payment_nr => PaymentNr,
                payload => JSON
            }),
            {error, json};
        {error, Error} ->
            log_create_error(PaymentId, Payload, Error, Context),
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"API error creating PayPal order">>,
                result => error,
                reason => Error,
                payment_id => PaymentId,
                payment_nr => PaymentNr
            }),
            {error, Error}
    end.

order_payload(Payment, Context) ->
    Currency = maps:get(<<"currency">>, Payment),
    Amount = maps:get(<<"amount">>, Payment),
    PaymentNr = maps:get(<<"payment_nr">>, Payment),
    CancelState = z_crypto:encode_value_expire(
        {paypal_cancel, PaymentNr},
        z_datetime:next_hour(calendar:universal_time(), ?CANCEL_STATE_EXPIRY_HOURS),
        Context),
    SuccessUrl = z_context:abs_url(
        z_dispatcher:url_for(
            paypal_payment_redirect,
            [ {payment_nr, PaymentNr}, {status, "ok"} ],
            none,
            Context),
        Context),
    CancelUrl = z_context:abs_url(
        z_dispatcher:url_for(
            paypal_payment_redirect,
            [
                {payment_nr, PaymentNr},
                {status, "cancel"},
                {state, CancelState}
            ],
            none,
            Context),
        Context),
    #{
        <<"intent">> => <<"CAPTURE">>,
        <<"purchase_units">> => [
            #{
                <<"reference_id">> => PaymentNr,
                <<"custom_id">> => PaymentNr,
                <<"invoice_id">> => PaymentNr,
                <<"description">> => valid_description(maps:get(<<"description">>, Payment)),
                <<"amount">> => #{
                    <<"currency_code">> => Currency,
                    <<"value">> => amount_string(Amount, Currency)
                }
            }
        ],
        <<"payment_source">> => #{
            <<"paypal">> => #{
                <<"experience_context">> => #{
                    <<"return_url">> => SuccessUrl,
                    <<"cancel_url">> => CancelUrl,
                    <<"user_action">> => <<"PAY_NOW">>,
                    <<"shipping_preference">> => <<"NO_SHIPPING">>
                }
            }
        }
    }.

valid_description(undefined) -> <<>>;
valid_description(D) when is_binary(D) -> D.

%% PayPal requires whole-unit values for these zero-decimal currencies.
-spec amount_string(number(), binary()) -> binary().
amount_string(Amount, Currency)
    when Currency =:= <<"HUF">>;
         Currency =:= <<"JPY">>;
         Currency =:= <<"TWD">>
->
    integer_to_binary(round(z_convert:to_float(Amount)));
amount_string(Amount, _Currency) ->
    z_convert:to_binary(io_lib:format("~.2f", [z_convert:to_float(Amount)])).

log_create_error(PaymentId, Args, Result, Context) ->
    m_payment_log:log(
        PaymentId,
        <<"ERROR">>,
        [
            {psp_module, mod_payment_paypal},
            {description, "API Error creating order with PayPal"},
            {request_result, Result},
            {request_args, Args}
        ],
        Context).

approve_url(#{ <<"links">> := Links }) when is_list(Links) ->
    case find_approve_url(Links) of
        {ok, _Url} = OK ->
            OK;
        {error, approve_url} = Error ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal order response has no approval URL">>,
                result => error,
                reason => approve_url,
                links => Links
            }),
            Error
    end;
approve_url(Order) ->
    ?LOG_ERROR(#{
        in => zotonic_mod_payment_paypal,
        text => <<"PayPal order response has no links">>,
        result => error,
        reason => approve_url,
        order => Order
    }),
    {error, approve_url}.

find_approve_url(Links) ->
    case approve_urls(<<"approve">>, Links) of
        [ Url | _ ] ->
            {ok, Url};
        [] ->
            case approve_urls(<<"payer-action">>, Links) of
                [ Url | _ ] -> {ok, Url};
                [] -> {error, approve_url}
            end
    end.

approve_urls(Rel, Links) ->
    lists:filtermap(
        fun
            (#{ <<"rel">> := Rel1, <<"href">> := Href })
                    when Rel1 =:= Rel, is_binary(Href), Href =/= <<>> ->
                {true, Href};
            (_) ->
                false
        end,
        Links).

%% @doc Cancel a local payment only if its PayPal order is still open.
%% Non-cancelable PayPal states are authoritative and are synchronized instead.
-spec cancel_payment(PaymentNr, OrderId, Context) -> Result
    when PaymentNr :: binary() | undefined,
         OrderId :: binary() | undefined,
         Context :: z:context(),
         LocalStatus :: new | pending | paid | cancelled | failed | refunded | error,
         PaypalStatus :: binary() | undefined,
         Result ::
             {ok, cancelled, {PaymentNr, cancelled}, PaypalStatus}
             | {ok, synchronized, {PaymentNr, LocalStatus}, PaypalStatus}
             | {error, term()}.
cancel_payment(undefined, _OrderId, _Context) ->
    {error, payment_nr};
cancel_payment(_PaymentNr, undefined, _Context) ->
    {error, order_id};
cancel_payment(PaymentNr, OrderId, Context) ->
    case fetch_order(OrderId, Context) of
        {ok, Order} ->
            cancel_payment_1(PaymentNr, OrderId, Order, Context);
        {error, _} = Error ->
            Error
    end.

cancel_payment_1(PaymentNr, OrderId, Order, Context) ->
    PaypalPaymentNr = payment_nr(Order),
    PaypalStatus = maps:get(<<"status">>, Order, undefined),
    case PaypalPaymentNr of
        PaymentNr ->
            case is_cancelable_order_status(PaypalStatus) of
                true ->
                    case mark_order_cancelled(PaymentNr, Context) of
                        {ok, Result} ->
                            {ok, cancelled, Result, PaypalStatus};
                        {error, _} = Error ->
                            Error
                    end;
                false ->
                    case sync_order_status_1(Order, Context) of
                        {ok, Result} ->
                            {ok, synchronized, Result, PaypalStatus};
                        {error, _} = Error ->
                            Error
                    end
            end;
        _ ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal cancel order does not match the local payment">>,
                result => error,
                reason => payment_nr_mismatch,
                payment_nr => PaymentNr,
                paypal_payment_nr => PaypalPaymentNr,
                paypal_order_id => OrderId
            }),
            {error, payment_nr}
    end.

is_cancelable_order_status(<<"CREATED">>) -> true;
is_cancelable_order_status(<<"SAVED">>) -> true;
is_cancelable_order_status(<<"PAYER_ACTION_REQUIRED">>) -> true;
is_cancelable_order_status(_) -> false.

%% @doc Mark a locally cancelled order as cancelled.
-spec mark_order_cancelled(PaymentNr, Context) -> {ok, {PaymentNr, Status}} | {error, term()}
    when PaymentNr :: binary() | undefined,
         Context :: z:context(),
         Status :: cancelled.
mark_order_cancelled(undefined, _Context) ->
    {error, payment_nr};
mark_order_cancelled(PaymentNr, Context) ->
    z_db:transaction(
        fun(Ctx) ->
            case z_db:qmap_row(
                "select status from payment where payment_nr = $1 for update",
                [PaymentNr],
                Ctx)
            of
                {ok, #{ <<"status">> := Status }}
                    when Status =:= <<"new">>;
                         Status =:= <<"pending">> ->
                    set_payment_status(PaymentNr, cancelled, calendar:universal_time(), #{}, Ctx);
                {ok, #{ <<"status">> := <<"cancelled">> }} ->
                    {ok, {PaymentNr, cancelled}};
                {ok, #{ <<"status">> := Status }} ->
                    {error, {status, z_convert:to_atom(Status)}};
                {error, enoent} ->
                    {error, notfound};
                {error, _} = Error ->
                    Error
            end
        end,
        Context).

%% @doc Capture an approved PayPal order and sync the resulting local status.
-spec capture_order(OrderId, Context) -> {ok, {PaymentNr, Status}} | {error, term()}
    when OrderId :: binary() | undefined,
         Context :: z:context(),
         PaymentNr :: binary(),
         Status :: new | pending | paid | cancelled | failed | refunded | error.
capture_order(undefined, _Context) ->
    {error, order_id};
capture_order(OrderId, Context) ->
    case is_valid_order_id(OrderId) of
        true ->
            % PayPal has no cancel operation for CAPTURE orders. Keep the
            % payment row locked while capturing, so a terminal local status
            % is also an effective merchant-side closure of the PayPal order.
            z_db:transaction(
                fun(Ctx) -> capture_order_locked(OrderId, Ctx) end,
                Context);
        false ->
            {error, order_id}
    end.

capture_order_locked(OrderId, Context) ->
    case z_db:qmap_row(
        "select payment_nr, status
         from payment
         where psp_module = $1
           and psp_external_id = $2
         for update",
        [mod_payment_paypal, OrderId],
        Context)
    of
        {ok, #{
            <<"payment_nr">> := _PaymentNr,
            <<"status">> := Status
        }}
            when Status =:= <<"new">>;
                 Status =:= <<"pending">> ->
            OrderId1 = z_convert:to_list(z_url:url_encode(OrderId)),
            Endpoint = "/v2/checkout/orders/" ++ OrderId1 ++ "/capture",
            case api_call(post, Endpoint, #{}, Context) of
                {ok, Capture} ->
                    sync_order_status_1(Capture, Context);
                {error, _} = Error ->
                    Error
            end;
        {ok, #{
            <<"payment_nr">> := PaymentNr,
            <<"status">> := <<"paid">>
        }} ->
            {ok, {PaymentNr, paid}};
        {ok, #{
            <<"payment_nr">> := PaymentNr,
            <<"status">> := Status
        }} ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"Refusing to capture PayPal order for closed payment">>,
                result => error,
                reason => payment_closed,
                payment_nr => PaymentNr,
                paypal_order_id => OrderId,
                status => z_convert:to_atom(Status)
            }),
            {error, {status, z_convert:to_atom(Status)}};
        {error, enoent} ->
            {error, notfound};
        {error, _} = Error ->
            Error
    end.

%% @doc Set the local status from an order map or an order id.
-spec sync_order_status(Order, Context) -> {ok, {PaymentNr, Status}} | {error, term()}
    when Order :: binary() | undefined | map(),
         Context :: z:context(),
         PaymentNr :: binary(),
         Status :: new | pending | paid | cancelled | failed | refunded | error.
sync_order_status(undefined, _Context) ->
    {error, order_id};
sync_order_status(OrderId, Context) when is_binary(OrderId) ->
    case fetch_order(OrderId, Context) of
        {ok, Order} -> sync_order_status_1(Order, Context);
        {error, _} = Error -> Error
    end;
sync_order_status(#{ <<"id">> := _ } = Order, Context) ->
    sync_order_status_1(Order, Context).

sync_order_status_1(Order, Context) ->
    DT = order_datetime(Order),
    case {payment_nr(Order), maps:get(<<"status">>, Order, undefined)} of
        {undefined, _Status} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal order status has no local payment reference">>,
                result => error,
                reason => payment_nr,
                order => Order
            }),
            {error, payment_nr};
        {PaymentNr, <<"CREATED">>} ->
            set_payment_status(PaymentNr, new, DT, Order, Context);
        {PaymentNr, <<"SAVED">>} ->
            set_payment_status(PaymentNr, new, DT, Order, Context);
        {PaymentNr, <<"PAYER_ACTION_REQUIRED">>} ->
            set_payment_status(PaymentNr, pending, DT, Order, Context);
        {PaymentNr, <<"APPROVED">>} ->
            set_payment_status(PaymentNr, pending, DT, Order, Context);
        {PaymentNr, <<"COMPLETED">>} ->
            set_payment_status(PaymentNr, paid, DT, Order, Context);
        {PaymentNr, <<"VOIDED">>} ->
            set_payment_status(PaymentNr, cancelled, DT, Order, Context);
        {PaymentNr, Status} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal order status is unknown">>,
                result => error,
                reason => order_status,
                payment_nr => PaymentNr,
                status => Status,
                order => Order
            }),
            {error, order_status}
    end.

payment_nr(#{ <<"purchase_units">> := [ Unit | _ ] }) ->
    maps:get(<<"custom_id">>, Unit, maps:get(<<"reference_id">>, Unit, undefined));
payment_nr(#{ <<"resource">> := Resource }) ->
    payment_nr(Resource);
payment_nr(_) ->
    undefined.

order_datetime(#{ <<"update_time">> := DT }) ->
    z_datetime:to_datetime(DT);
order_datetime(#{ <<"create_time">> := DT }) ->
    z_datetime:to_datetime(DT);
order_datetime(_) ->
    calendar:universal_time().

set_payment_status(PaymentNr, Status, DT, Order, Context)
    when Status =:= new;
         Status =:= pending ->
    set_open_payment_status(PaymentNr, Status, DT, Order, Context);
set_payment_status(PaymentNr, Status, DT, Order, Context) ->
    set_payment_status_1(PaymentNr, Status, DT, Order, Context).

set_open_payment_status(PaymentNr, Status, DT, Order, Context) ->
    z_db:transaction(
        fun(Ctx) ->
            case z_db:qmap_row(
                "select id, status
                 from payment
                 where payment_nr = $1
                 for update",
                [PaymentNr],
                Ctx)
            of
                {ok, #{ <<"status">> := CurrentStatus }}
                    when CurrentStatus =:= <<"new">>;
                         CurrentStatus =:= <<"pending">> ->
                    set_payment_status_1(PaymentNr, Status, DT, Order, Ctx);
                {ok, #{
                    <<"id">> := PaymentId,
                    <<"status">> := CurrentStatus
                }} ->
                    log_order(PaymentId, Order, Ctx),
                    ?LOG_WARNING(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"Ignoring open PayPal status for closed payment">>,
                        result => ok,
                        reason => payment_closed,
                        payment_nr => PaymentNr,
                        paypal_order_id => maps:get(<<"id">>, Order, undefined),
                        paypal_status => maps:get(<<"status">>, Order, undefined),
                        status => z_convert:to_atom(CurrentStatus)
                    }),
                    {ok, {PaymentNr, z_convert:to_atom(CurrentStatus)}};
                {error, enoent} ->
                    {error, notfound};
                {error, _} = Error ->
                    Error
            end
        end,
        Context).

set_payment_status_1(PaymentNr, Status, DT, Order, Context) ->
    case m_payment:get(PaymentNr, Context) of
        {ok, #{ <<"id">> := PaymentId, <<"status">> := CurrentStatus }} ->
            log_order(PaymentId, Order, Context),
            ok = maybe_update_contact(PaymentId, Order, CurrentStatus, Status, Context),
            case mod_payment:set_payment_status(PaymentId, Status, DT, Context) of
                ok -> {ok, {PaymentNr, Status}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal status for unknown payment">>,
                result => error,
                reason => notfound,
                payment_nr => PaymentNr
            }),
            Error
    end.

log_order(PaymentId, Order, Context) ->
    m_payment_log:log(
        PaymentId,
        <<"paypal.order">>,
        #{
            <<"psp_module">> => mod_payment_paypal,
            <<"psp_external_log_id">> => maps:get(<<"id">>, Order, undefined),
            <<"paypal_order">> => Order
        },
        Context).

%% @doc Retrieve an order from PayPal.
fetch_order(OrderId, Context) ->
    case is_valid_order_id(OrderId) of
        true ->
            OrderId1 = z_convert:to_list(z_url:url_encode(OrderId)),
            Url = "/v2/checkout/orders/" ++ OrderId1,
            api_call(get, Url, undefined, Context);
        false ->
            {error, order_id}
    end.

maybe_update_contact(_PaymentId, _Order, _CurrentStatus, new, _Context) ->
    ok;
maybe_update_contact(PaymentId, Order, new, _Status, Context) ->
    case m_payment:maybe_update_contact(PaymentId, payment_link_contact(Order), Context) of
        ok ->
            ok;
        {error, need_contact} ->
            maybe_fetch_and_update_contact(PaymentId, Order, Context);
        {error, _} = Error ->
            Error
    end;
maybe_update_contact(_PaymentId, _Order, _CurrentStatus, _Status, _Context) ->
    ok.

maybe_fetch_and_update_contact(PaymentId, Order, Context) ->
    case payment_link_order_id(Order) of
        undefined ->
            ok;
        OrderId ->
            case fetch_order(OrderId, Context) of
                {ok, FetchedOrder} ->
                    case m_payment:maybe_update_contact(
                        PaymentId,
                        payment_link_contact(FetchedOrder),
                        Context)
                    of
                        ok -> ok;
                        {error, need_contact} -> ok;
                        {error, _} = Error -> Error
                    end;
                {error, _} ->
                    ok
            end
    end.

payment_link_order_id(#{ <<"id">> := OrderId, <<"purchase_units">> := _ }) ->
    OrderId;
payment_link_order_id(Order) ->
    capture_order_id(Order).

payment_link_contact(Order) ->
    Payer = maps:get(<<"payer">>, Order, #{}),
    Address = invoice_address(Order),
    maps:merge(
        paypal_address_props(Address),
        maps:merge(
            paypal_name_props(Payer),
            #{
                <<"email">> => maps:get(<<"email_address">>, Payer, undefined),
                <<"phone">> => paypal_phone(Payer)
            })).

invoice_address(#{ <<"payer">> := #{ <<"address">> := Address } }) when is_map(Address) ->
    Address;
invoice_address(#{ <<"payment_source">> := PaymentSource }) when is_map(PaymentSource) ->
    first_address([
        [ <<"card">>, <<"billing_address">> ],
        [ <<"paypal">>, <<"address">> ],
        [ <<"paypal">>, <<"billing_address">> ]
    ], PaymentSource);
invoice_address(_) ->
    #{}.

first_address([Path | Rest], Map) ->
    case nested_map(Path, Map) of
        Address when is_map(Address) ->
            Address;
        _ ->
            first_address(Rest, Map)
    end;
first_address([], _Map) ->
    #{}.

nested_map([Key | Rest], Map) when is_map(Map) ->
    nested_map(Rest, maps:get(Key, Map, undefined));
nested_map([], Value) ->
    Value;
nested_map(_, _) ->
    undefined.

paypal_name_props(Payer) ->
    case maps:get(<<"name">>, Payer, undefined) of
        #{ <<"given_name">> := GivenName, <<"surname">> := Surname } ->
            #{
                <<"name_first">> => GivenName,
                <<"name_surname">> => Surname
            };
        #{ <<"surname">> := Surname } ->
            #{ <<"name_surname">> => Surname };
        _ ->
            #{}
    end.


paypal_address_props(Address) when is_map(Address) ->
    #{
        <<"address_street_1">> => maps:get(<<"address_line_1">>, Address, undefined),
        <<"address_street_2">> => maps:get(<<"address_line_2">>, Address, undefined),
        <<"address_postcode">> => maps:get(<<"postal_code">>, Address, undefined),
        <<"address_city">> => maps:get(<<"admin_area_2">>, Address, undefined),
        <<"address_state">> => maps:get(<<"admin_area_1">>, Address, undefined),
        <<"address_country">> => maps:get(<<"country_code">>, Address, undefined)
    };
paypal_address_props(_) ->
    #{}.

paypal_phone(#{ <<"phone">> := #{ <<"phone_number">> := #{ <<"national_number">> := Phone } } }) ->
    Phone;
paypal_phone(_) ->
    undefined.

%% @doc Return the URL to the order page on the PayPal dashboard.
-spec payment_url(OrderId, Context) -> Url
    when OrderId :: binary(),
         Context :: z:context(),
         Url :: binary().
payment_url(OrderId, Context) ->
    case is_live(Context) of
        true ->
            <<"https://www.paypal.com/activity/payment/", OrderId/binary>>;
        false ->
            <<"https://www.sandbox.paypal.com/activity/payment/", OrderId/binary>>
    end.

webhook_event(#{ <<"event_type">> := EventType, <<"resource">> := Resource }, Context) ->
    case EventType of
        <<"CHECKOUT.ORDER.APPROVED">> ->
            sync_webhook_order(Resource, Context);
        <<"CHECKOUT.ORDER.COMPLETED">> ->
            sync_webhook_order(Resource, Context);
        <<"PAYMENT.CAPTURE.COMPLETED">> ->
            sync_capture_completed(Resource, Context);
        <<"PAYMENT.CAPTURE.DENIED">> ->
            sync_capture_status(Resource, failed, Context);
        <<"PAYMENT.CAPTURE.DECLINED">> ->
            sync_capture_status(Resource, failed, Context);
        <<"PAYMENT.CAPTURE.PENDING">> ->
            sync_capture_status(Resource, pending, Context);
        <<"PAYMENT.CAPTURE.REFUNDED">> ->
            sync_capture_status(Resource, refunded, Context);
        <<"PAYMENT.CAPTURE.REVERSED">> ->
            sync_capture_status(Resource, refunded, Context);
        _ ->
            ok
    end;
webhook_event(Payload, _Context) ->
    ?LOG_ERROR(#{
        in => zotonic_mod_payment_paypal,
        text => <<"Unknown payload when processing PayPal webhook data">>,
        result => error,
        reason => payload,
        payload => Payload
    }),
    {error, payload}.

sync_webhook_order(#{ <<"id">> := OrderId }, Context) ->
    case sync_order_status(OrderId, Context) of
        {ok, {_PaymentNr, _Status}} -> ok;
        {error, _} = Error -> Error
    end;
sync_webhook_order(Payload, _Context) ->
    ?LOG_ERROR(#{
        in => zotonic_mod_payment_paypal,
        text => <<"PayPal webhook order payload has no id">>,
        result => error,
        reason => order_id,
        payload => Payload
    }),
    {error, order_id}.

sync_capture_status(Resource, Status, Context) ->
    case capture_payment_nr(Resource) of
        undefined ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal capture webhook has no local payment reference">>,
                result => error,
                reason => payment_nr,
                resource => Resource
            }),
            {error, payment_nr};
        PaymentNr ->
            case set_payment_status(PaymentNr, Status, order_datetime(Resource), Resource, Context) of
                {ok, {_PaymentNr, _Status}} -> ok;
                {error, _} = Error -> Error
            end
    end.

sync_capture_completed(Resource, Context) ->
    case capture_order_id(Resource) of
        undefined ->
            sync_capture_status(Resource, paid, Context);
        OrderId ->
            sync_webhook_order(#{ <<"id">> => OrderId }, Context)
    end.

capture_payment_nr(#{ <<"custom_id">> := PaymentNr }) ->
    PaymentNr;
capture_payment_nr(#{ <<"invoice_id">> := PaymentNr }) ->
    PaymentNr;
capture_payment_nr(_) ->
    undefined.

capture_order_id(#{ <<"supplementary_data">> := #{ <<"related_ids">> := #{ <<"order_id">> := OrderId } } }) ->
    OrderId;
capture_order_id(_) ->
    undefined.

%% @doc Paypal order ids are in the format: ^[A-Z0-9]+$ and have a length of 1..36 characters.
%% Also accept lowercase a-z and a bit more characters, just to be future proof.
is_valid_order_id(OrderId)
    when
        is_binary(OrderId),
        size(OrderId) =< ?MAX_ORDERID_SIZE,
        size(OrderId) >= ?MIN_ORDERID_SIZE ->
    is_valid_order_id_1(OrderId);
is_valid_order_id(_OrderId) ->
    false.

is_valid_order_id_1(<<>>) ->
    true;
is_valid_order_id_1(<<C, T/binary>>)
    when
        (C >= $A andalso C =< $Z) orelse
        (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) ->
    is_valid_order_id_1(T);
is_valid_order_id_1(_) ->
    false.

is_valid_webhook_signature(Event, Context) ->
    case webhook_id(Context) of
        {ok, WebhookId} ->
            Payload = #{
                <<"auth_algo">> => z_context:get_req_header(<<"paypal-auth-algo">>, Context),
                <<"cert_url">> => z_context:get_req_header(<<"paypal-cert-url">>, Context),
                <<"transmission_id">> => z_context:get_req_header(<<"paypal-transmission-id">>, Context),
                <<"transmission_sig">> => z_context:get_req_header(<<"paypal-transmission-sig">>, Context),
                <<"transmission_time">> => z_context:get_req_header(<<"paypal-transmission-time">>, Context),
                <<"webhook_id">> => WebhookId,
                <<"webhook_event">> => Event
            },
            case api_call(post, "/v1/notifications/verify-webhook-signature", Payload, Context) of
                {ok, #{ <<"verification_status">> := <<"SUCCESS">> }} ->
                    true;
                {ok, Verification} ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal webhook signature verification failed">>,
                        result => error,
                        reason => verification_failed,
                        verification => Verification
                    }),
                    false;
                {error, Error} ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal webhook signature verification error">>,
                        result => error,
                        reason => Error
                    }),
                    false
            end;
        {error, _} ->
            false
    end.

webhook_id(Context) ->
    case m_config:get_value(mod_payment_paypal, webhook_id, Context) of
        undefined -> {error, enoent};
        <<>> -> {error, enoent};
        WebhookId -> {ok, WebhookId}
    end.

api_call(Method, Endpoint, Payload, Context) ->
    case access_token(Context) of
        {ok, Token} ->
            Url = <<(base_url(Context))/binary, (z_convert:to_binary(Endpoint))/binary>>,
            Options = fetch_options(<<"Bearer ", Token/binary>>, <<"application/json">>),
            Payload1 = case Method of
                get -> <<>>;
                _ -> Payload
            end,
            ?LOG_DEBUG(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal API call">>,
                method => Method,
                endpoint => Endpoint
            }),
            fetch_json(Method, Url, Payload1, Options, Context);
        {error, _} = Error ->
            Error
    end.

fetch_json(Method, Url, Payload, Options, Context) ->
    case z_fetch:fetch_json(Method, Url, Payload, Options, Context) of
        {ok, _} = OK ->
            OK;
        {error, {404, FinalUrl, Headers, _Size, Body}} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal API resource not found">>,
                result => error,
                reason => notfound,
                url => FinalUrl,
                payload => Body,
                headers => Headers
            }),
            {error, 404};
        {error, {Code, FinalUrl, Headers, _Size, Body}} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal API error">>,
                result => error,
                reason => {code, Code},
                url => FinalUrl,
                payload => Body,
                headers => Headers
            }),
            {error, Code};
        {error, _} = Error ->
            Error
    end.

access_token(Context) ->
    case credentials(Context) of
        {ok, ClientId, Secret} ->
            Url = <<(base_url(Context))/binary, "/v1/oauth2/token">>,
            Options = fetch_options(basic_auth(ClientId, Secret), <<"application/x-www-form-urlencoded">>),
            Payload = [{<<"grant_type">>, <<"client_credentials">>}],
            case fetch_json(post, Url, Payload, Options, Context) of
                {ok, #{ <<"access_token">> := Token }} ->
                    {ok, Token};
                {ok, JSON} ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal access token response has no token">>,
                        result => error,
                        reason => token,
                        payload => JSON
                    }),
                    {error, token};
                {error, _} = Error ->
                    Error
            end;
        {error, enoent} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal client id or secret not set">>,
                result => error,
                reason => credentials_not_set
            }),
            {error, credentials_not_set}
    end.

basic_auth(ClientId, Secret) ->
    Encoded = base64:encode(<<ClientId/binary, ":", Secret/binary>>),
    <<"Basic ", Encoded/binary>>.

fetch_options(Authorization, ContentType) ->
    [
        {authorization, Authorization},
        {content_type, ContentType},
        {timeout, ?TIMEOUT_REQUEST},
        {connect_timeout, ?TIMEOUT_CONNECT}
    ].

credentials(Context) ->
    ClientId = m_config:get_value(mod_payment_paypal, client_id, Context),
    Secret = m_config:get_value(mod_payment_paypal, secret, Context),
    case {ClientId, Secret} of
        {undefined, _} -> {error, enoent};
        {<<>>, _} -> {error, enoent};
        {_, undefined} -> {error, enoent};
        {_, <<>>} -> {error, enoent};
        _ -> {ok, ClientId, Secret}
    end.

base_url(Context) ->
    case is_live(Context) of
        true -> <<"https://api-m.paypal.com">>;
        false -> <<"https://api-m.sandbox.paypal.com">>
    end.

is_live(Context) ->
    m_config:get_boolean(mod_payment_paypal, is_live, Context).
