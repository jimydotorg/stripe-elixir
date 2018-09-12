defmodule Stripe do
  @moduledoc """
  Main module for handling sending/receiving requests to Stripe's API
  """

  @default_api_endpoint "https://api.stripe.com/v1/"
  @client_version Mix.Project.config[:version]

  def version do
    @client_version
  end

  alias Stripe.{APIConnectionError,
                APIError,
                AuthenticationError,
                CardError,
                InvalidRequestError,
                RateLimitError}

  @missing_secret_key_error_message"""
    The secret_key settings is required to use stripe. Please include your
    stripe secret api key in your application config file like so:

      config :stripe, secret_key: YOUR_SECRET_KEY

    Alternatively, you can also set the secret key as an environment variable:

      STRIPE_SECRET_KEY=YOUR_SECRET_KEY
  """

  defp get_secret_key do
    System.get_env("STRIPE_SECRET_KEY") || 
    Application.get_env(:stripe, :secret_key) || 
    raise AuthenticationError, message: @missing_secret_key_error_message
  end

  defp get_api_endpoint do
    System.get_env("STRIPE_API_ENDPOINT") || 
    Application.get_env(:stripe, :api_endpoint) || 
    @default_api_endpoint
  end

  defp log_requests, do: Application.get_env(:stripe, :log)

  defp request_url(endpoint) do
    Path.join(get_api_endpoint(), endpoint)
  end

  defp request_url(endpoint, [], action) do
    request_url(endpoint)
  end

  defp request_url(endpoint, data, action) when action in [:post, :put] do
    request_url(endpoint)
  end

  defp request_url(endpoint, data, action) do
    base_url = request_url(endpoint)
    query_params = Stripe.Utils.encode_data(data)
    "#{base_url}?#{query_params}"
  end

  defp request_body(data, action) when action in [:post, :put] do
    Stripe.Utils.encode_data(data)
  end

  defp request_body(_, _), do: ""

  defp create_headers(opts, action) do
    headers = [
      {"Authorization", "Bearer #{get_secret_key()}"},
      {"User-Agent", "Stripe/v1 stripe-elixir/#{@client_version}"}
    ]

    headers = case action do
      :post -> [{"Content-Type", "application/x-www-form-urlencoded"} | headers]
      :put -> [{"Content-Type", "application/x-www-form-urlencoded"} | headers]
      _ -> headers
    end

    headers = case Keyword.get(opts, :stripe_account) do 
      nil -> headers 
      account_id -> [{"Stripe-Account", account_id} | headers]
    end

    headers = case Keyword.get(opts, :stripe_api_version) do 
      nil -> headers 
      version -> [{"Stripe-Version", version} | headers]
    end

    headers = case Keyword.get(opts, :idempotency_key) do 
      nil -> headers 
      key -> [{"Idempotency-Key", key} | headers]
    end

    headers
  end

  def request(action, endpoint, data, opts) when action in [:get, :post, :put, :delete] do

    url = request_url(endpoint, data, action)
    body = request_body(data, action)
    if log_requests(), do: IO.write("#{action} #{url}\n#{body}\n\n")

    HTTPoison.request(action, url, body, create_headers(opts, action))
    |> handle_response

  end

  defp handle_response({:ok, %{body: body, status_code: code}}) when code >= 200 and code < 300 do
    {:ok, process_response_body(body)}
  end

  defp handle_response({:ok, %{body: body, status_code: code}}) do
    %{"message" => message} = error =
      body
      |> process_response_body
      |> Map.fetch!("error")

    error_struct =
      case code do
        401 ->
          %AuthenticationError{message: message}
        402 ->
          %CardError{message: message, code: error["code"], param: error["param"]}
        429 ->
          %RateLimitError{message: message}
        code when code >= 400 and code < 500 ->
          %InvalidRequestError{message: message, param: error["param"]}
        _ ->
          %APIError{message: message}
      end

    {:error, error_struct}
  end

  defp handle_response({:error, %HTTPoison.Error{reason: reason}}) do
    %APIConnectionError{message: "Network Error: #{reason}"}
  end

  defp process_response_body(body) do
    if log_requests(), do: IO.write("response: #{body}\n")
    Poison.decode! body
  end
end
