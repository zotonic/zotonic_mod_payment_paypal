%% @copyright 2026 Marc Worrell
%% @doc Opt-in account discovery through PayPal Transaction Search.
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

-module(payment_paypal_poll).
-export([page/2, sync/2]).
-include_lib("zotonic_mod_payment/include/payment.hrl").

-spec page(#payment_psp_poll{}, z:context()) -> {ok, list(), term()} | {error, term()}.
page(#payment_psp_poll{since = Since, until = Until, cursor = Cursor}, Context) ->
    case m_config:get_boolean(mod_payment_paypal, enable_reporting_polling, Context) of
        false -> {error, reporting_disabled};
        true ->
            Page = case Cursor of undefined -> 1; N when is_integer(N), N > 0 -> N end,
            case list(Since, Until, [{page, Page}, {page_size, 500}], Context) of
                {ok, #{<<"transaction_details">> := Records, <<"total_pages">> := Total}}
                    when is_list(Records), is_integer(Total), Total >= 0 ->
                    case payments(Records, Context, []) of
                        {ok, Payments} ->
                            Next = case Page < Total of true -> Page + 1; false -> undefined end,
                            {ok, Payments, Next};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error;
                _ -> {error, transaction_list}
            end
    end.

list(Since, Until, Args, Context) ->
    Query = mochiweb_util:urlencode([
        {start_date, rfc3339(Since)}, {end_date, rfc3339(Until)},
        {fields, "transaction_info"}, {balance_affecting_records_only, "Y"} | Args]),
    m_payment_paypal_api:api_call(get, "/v1/reporting/transactions?" ++ Query, [], Context).

rfc3339(Date) ->
    calendar:system_time_to_rfc3339(z_datetime:datetime_to_timestamp(Date),
        [{unit, second}, {offset, "Z"}]).

payments([], _, Acc) -> {ok, lists:reverse(Acc)};
payments([#{<<"transaction_info">> := Info} | Rest], Context, Acc) ->
    case incoming(Info) of
        false -> payments(Rest, Context, Acc);
        true ->
            case resolve(Info, Context) of
                {ok, Data} ->
                    Created = z_convert:to_datetime(maps:get(<<"transaction_initiation_date">>, Info)),
                    Updated = z_convert:to_datetime(maps:get(<<"transaction_updated_date">>, Info)),
                    payments(Rest, Context, [Data#{created_at => Created, updated_at => Updated} | Acc]);
                {error, _} = Error -> Error
            end
    end.

%% T00 identifies payments. Positive amounts are incoming; fees, conversions,
%% withdrawals and refunds have other event groups and are not new payments.
incoming(#{<<"transaction_event_code">> := <<"T00", _, _>>,
           <<"transaction_amount">> := #{<<"value">> := Value}}) ->
    z_convert:to_float(Value) > 0;
incoming(_) -> false.

%% Prefer the order identity used by webhooks. Never assume a reporting
%% transaction is a v2 capture: older PayPal products are also present here.
resolve(#{<<"paypal_reference_id_type">> := <<"ODR">>,
          <<"paypal_reference_id">> := OrderId}, Context) ->
    case m_payment_paypal_api:fetch_order(OrderId, Context) of
        {ok, Order} -> m_payment_paypal_api:webhook_payment(Order);
        {error, _} = Error -> Error
    end;
resolve(#{<<"transaction_event_code">> := <<"T0006">>, <<"transaction_id">> := Id} = Info, Context) ->
    Path = <<"/v2/payments/captures/", (uri_string:quote(Id))/binary>>,
    case m_payment_paypal_api:api_call(get, Path, [], Context) of
        {ok, #{<<"supplementary_data">> := #{<<"related_ids">> := #{<<"order_id">> := OrderId}}}} ->
            resolve(Info#{<<"paypal_reference_id_type">> => <<"ODR">>,
                <<"paypal_reference_id">> => OrderId}, Context);
        {ok, Capture} -> m_payment_paypal_api:webhook_payment(Capture);
        {error, 404} -> {ok, payment(Info)};
        {error, _} = Error -> Error
    end;
resolve(Info, _Context) -> {ok, payment(Info)}.

payment(#{<<"transaction_id">> := Id, <<"transaction_status">> := Status,
          <<"transaction_updated_date">> := Date,
          <<"transaction_amount">> := #{<<"value">> := Value, <<"currency_code">> := Currency}} = Info) ->
    #{psp_external_id => <<"capture:", Id/binary>>, amount => z_convert:to_float(Value),
      currency => Currency, status => status(Status), status_date => z_convert:to_datetime(Date),
      description => maps:get(<<"transaction_subject">>, Info, <<>>),
      psp_data => #{<<"reporting_transaction">> => Info}}.

status(<<"S">>) -> paid;
status(<<"P">>) -> pending;
status(<<"D">>) -> failed;
status(<<"V">>) -> refunded.

%% Legacy reporting imports do not necessarily have a v2 capture endpoint.
%% Keep the existing known-payment sync working for their pending statuses.
-spec sync(map(), z:context()) -> ok | {error, term()}.
sync(#{<<"transaction_id">> := Id, <<"transaction_initiation_date">> := Date}, Context) ->
    case m_config:get_boolean(mod_payment_paypal, enable_reporting_polling, Context) of
        false -> {error, reporting_disabled};
        true ->
            Time = z_datetime:datetime_to_timestamp(z_convert:to_datetime(Date)),
            Since = z_datetime:timestamp_to_datetime(Time - 1),
            Until = z_datetime:timestamp_to_datetime(Time + 1),
            case list(Since, Until, [{transaction_id, Id}], Context) of
                {ok, #{<<"transaction_details">> := Records}} ->
                    case [I || #{<<"transaction_info">> := #{<<"transaction_id">> := T} = I} <- Records,
                               T =:= Id, incoming(I)] of
                        [Info] ->
                            case mod_payment:receive_payment(mod_payment_paypal, payment(Info), Context) of
                                {ok, _} -> ok;
                                {error, _} = Error -> Error
                            end;
                        _ -> {error, reporting_transaction}
                    end;
                {error, _} = Error -> Error;
                _ -> {error, transaction_list}
            end
    end.
