defmodule Vault do
  @moduledoc """
  The main module for configuring and interacting with HashiCorp's Vault.

  When possible, it tries to emulate the CLI, with `read`, `write`, `list` and 
  `delete` methods. An additional `request` method is provided when you need
  further flexibility. 

  ## API Preview

  ```elixir
  vault =
    Vault.new([
      engine: Vault.Engine.KVV2, 
      auth: Vault.Auth.UserPass 
    ])
    |> Vault.auth(%{username: "username", password: "password"})

  {:ok, db_pass} = Vault.read(vault, "secret/path/to/password")
  {:ok, %{"version" => 1 }} = Vault.write(vault, "secret/path/to/creds", %{secret: "secrets!"})
  ```

  ## Flexibility

  Hashicorp's Vault is highly configurable. Rather than cover every possible option,
  this library strives to be flexible and adaptable. Auth backends, Secret 
  Engines, and Http clients, and JSON parsers are all replacable, and each 
  behaviour asks for a minimal behaviour contract. 

  ### HTTP Adapters

  The following HTTP Adapters are provided:
  - `Tesla` with `Vault.HTTP.Tesla`
    - Can be configured to use `:hackney`, `:ibrowse`, or `:httpc` (and in turn, plays nice with `HTTPoison`, and `HTTPotion`)

  ### JSON Adapters

  Most JSON libraries provide the same methods, so no default adapter is needed.
  You can use `Jason`, `JSX`, `Poison`, or whatever encoder you want.

  Defaults to `Jason` if present, falling back to `Poison` if present,
  ultimately falling back to `nil`.

  See `Vault.JSON.Adapter` for the full behaviour interface.

  ### Auth Adapters

  Adapters have been provided for the following auth backends:
  - [AppRole](https://www.vaultproject.io/api/auth/approle/index.html) with `Vault.Auth.Approle`
  - [Azure](https://www.vaultproject.io/api/auth/approle/index.html) with `Vault.Auth.Azure`
  - [GitHub](https://www.vaultproject.io/api/auth/github/index.html) with `Vault.Auth.Github`
  - [GoogleCloud](https://www.vaultproject.io/api/auth/gcp/index.html) with with `Vault.Auth.GoogleCloud`
  - [JWT](https://www.vaultproject.io/api/auth/jwt/index.html) with `Vault.Auth.JWT`
  - [Kubernetes](https://www.vaultproject.io/api/auth/jwt/index.html) with `Vault.Auth.Kubernetes`
  - [LDAP](https://www.vaultproject.io/api/auth/ldap/index.html) with `Vault.Auth.LDAP`
  - [UserPass](https://www.vaultproject.io/api/auth/userpass/index.html) with `Vault.Auth.UserPass`
  - [Token](https://www.vaultproject.io/api/auth/token/index.html#lookup-a-token-self-) with `Vault.Auth.Token`

  In addition to the above, a generic backend is also provided (`Vault.Auth.Generic`). 
  If support for auth provider is missing, you can still get up and running 
  quickly, without writing a new adapter.

  ### Secret Engines

  Most of Vault's Secret Engines use a replacable API. The `Vault.Engine.Generic`
  adapter should handle most use cases for secret fetching. This is also the default value.

  Vault's KV version 2  broke away from the standard REST convention. So KV has been given
  its own adapter:
  - [Key/Value](https://www.vaultproject.io/api/secret/kv/index.html)
    - [v1](https://www.vaultproject.io/api/secret/kv/kv-v1.html) with `Vault.Engine.KVV1`
    - [v2](https://www.vaultproject.io/api/secret/kv/kv-v2.html) with `Vault.Engine.KVV1`


  ### Additional request methods

  The core library only handles the basics around secret fetching. If you need to
  access additional API endpoints, this library also provides a `Vault.request` 
  method. This should allow you to tap into the complete vault REST API, while still
  benefiting from token control, JSON parsing, and other HTTP client nicities.

  ## Setup and Usage

  First, ensure that adapter dependancies are part of your dependancies and applications:

  ```
  def application do
    [
      extra_applications: [:logger, :tesla, :hackney,] # or :ibrowse
      mod: {MyApp.Application, []}
    ]
  end

  def deps do
    [
      # tesla, required for Vault.HTTP.Tesla
      {:tesla, "~> 1.0.0", },

      # pick your HTTP client - ibrowse, hackney, or if you're feeling bold, httpc.
      {:ibrowse, "~> 4.4.0", },
      {:hackney, "~> 1.6", },

      # Pick your json parser
      {:jason, ">= 1.0.0", },
      {:poison, "~> 3.0", },
    ]
      
  end
  ```



  Example usage:

  ```
  vault = 
    Vault.new([
      engine: Vault.Engine.KVV2,
      auth: Vault.Auth.UserPass, 
      credentials: %{username: "username", password: "password"}
    ]) 
    |> Vault.auth()

  {:ok, db_pass} = Vault.read(vault, "secret/path/to/password")
  {:ok, aws_creds} = Vault.read(vault, "secret/path/to/creds")
  ```

  You can configure the client up front, or change configuration dynamically.

  ```
    vault = 
      Vault.new() # use defaults, or application configuration
      |> Vault.set_auth(Vault.Auth.Approle)
      |> Vault.auth(%{role_id: "role_id", secret_id: "secret_id"})

    {:ok, db_pass} = Vault.read(vault, "secret/path/to/password")

    vault = Vault.set_engine(Vault.Engine.KVV2) // switch to versioned secrets

    {:ok, db_pass} = Vault.write(vault, "kv/path/to/password", %{ password: "db_pass" })
  ```
  """

  require Logger

  @http if Code.ensure_loaded?(Tesla), do: Vault.HTTP.Tesla, else: nil
  @json if Code.ensure_loaded?(Jason),
          do: Jason,
          else: if(Code.ensure_loaded?(Poison), do: Poison, else: nil)

  defstruct http: @http,
            json: @json,
            host: nil,
            auth: nil,
            auth_path: nil,
            engine: Vault.Engine.Generic,
            token: nil,
            token_expires_at: nil,
            http_options: [],
            credentials: %{}

  @type options :: map() | Keyword.t()
  @type http :: Vault.HTTP.Adapter.t() | nil
  @type auth :: Vault.Auth.Adapter.t() | nil
  @type auth_path :: String.t()
  @type engine :: Vault.Engine.Adapter.t() | nil
  @type json :: Vault.Json.Adapter.t() | nil
  @type host :: String.t()

  @type token_expires_at :: NaiveDateTime.t()
  @type token :: String.t() | nil

  @type credentials :: map()

  @type method :: :get | :put | :post | :patch | :head | :delete

  @type t :: %__MODULE__{
          http: http,
          json: json,
          host: host,
          auth: auth,
          auth_path: auth_path,
          engine: engine,
          token: token,
          token_expires_at: token_expires_at,
          credentials: credentials
        }

  @doc """
  Create a new client. Optionally provide a keyword list or map of options for 
  configuration.

  ## Examples

  Return a default Vault client:
  ```
  vault = Vault.new()
  ```

  Return a fully initialized Vault Client:
  ```
    vault = Vault.new(%{
      http: Vault.HTTP.Tesla,
      host: myvault.instance.com,
      auth: Vault.Auth.JWT,
      auth_path: 'jwt',
      engine: Vault.Engine.Generic,
      token: "abc123",
      token_expires_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(30, :second),
      credentials: %{role_id: "dev-role", jwt: "averylongstringoflettersandnumbers..."}
    })

  ```

  ### Options
  The following options can be provided as part of the `:vault` application config, or 
  as a Keyword List or Map of options. Runtime configuration will always take 
  precedence.

  * `:auth` - Module for your Auth adapter.
  * `:auth_path` - Path to use for your auth adapter. Provided adapters have their own default paths. Check your adapter for details.
  * `:engine` Module for your Secret Engine adapter. Defaults to `Vault.Engine.Generic`.
  * `:host` - host of your vault instance. Should contain the port, if needed. Should not contain a trailing slash. Defaults to `System.get_env("VAULT_ADDR")`.
  * `:http` - Module for your http adapter. Defaults to `Vault.HTTP.Tesla` when `:tesla` is present.
  * `:http_options` - A keyword list of options to your HTTP adapter.
  * `:token` - A vault token.
  * `:token_expires_at` A `NaiveDateTime` instance that represents when the token expires, in utc.
  * `:credentials` - The credentials to use when authenticating with your Auth adapter.

  """

  @spec new(options) :: t
  def new(params \\ %{}) when is_list(params) or is_map(params) do
    params = Map.merge(%{host: System.get_env("VAULT_ADDR")}, Map.new(params))

    struct(__MODULE__, params)
  end

  @doc """
  Set the host of your vault instance. 

  ## Examples

  The host can be fetched from anywhere, as long as it's a string.
  ```
  vault = Vault.set_host(vault, System.get_env("VAULT_ADDR"))
  ```

  The port should be provided if needed, along with the protocol.
  ```
  vault = Vault.set_host(vault, "https://my-vault.host.com:12345")
  ```
  """
  @spec set_host(t, host) :: t
  def set_host(%__MODULE__{} = vault, host) when is_binary(host) do
    # TODO - move host formatting niceties to a shared location.
    host = if String.starts_with?(host, "http"), do: host, else: "https://" <> host

    %{vault | host: String.trim_trailing(host, "/")}
  end

  @doc """
  Set the http module used to make API calls.

  ## Examples

  Should be a module that meets the `Vault.HTTP.Adapter` behaviour.
  ```
  vault = Vault.set_http(vault, Vault.HTTP.Tesla)
  ```
  """
  @spec set_http(t, http) :: t
  def set_http(%__MODULE__{} = vault, http) do
    %{vault | http: http}
  end

  @doc """
  Set the secret engine for the client.

  ## Examples
  The secret engine should be a module that meets the `Vault.Engine.Adapter` behaviour.

  ```
  vault = Vault.set_engine(vault, Vault.Engine.KVV2)
  ```
  """
  @spec set_engine(t, engine) :: t
  def set_engine(%__MODULE__{} = vault, engine) do
    %{vault | engine: engine}
  end

  @doc """
  Set the backend to use for authenticating the client.

  ## Examples
  The auth backend should be a module that meets the `Vault.Auth.Adapter` behaviour.

  ```
  vault = Vault.set_auth(vault, Vault.Auth.Approle)
  ```
  """
  @spec set_auth(t, auth) :: t
  def set_auth(%__MODULE__{} = vault, auth) do
    %{vault | auth: auth}
  end

  @doc """
  Set the path used when logging in with your auth adapter. 

  ## Examples 

  Auth backends can be mounted at any path on `/auth/`. If left unset, the auth adapter may 
  provide a default, eg `userpass`.  See your Auth adapter for details.

  ```
  vault = Vault.set_auth_path(vault, "auth-path")
  ```
  """
  @spec set_auth_path(t, auth_path) :: t
  def set_auth_path(%__MODULE__{} = vault, auth_path) when is_binary(auth_path) do
    path = String.trim_leading(auth_path, "/")
    %{vault | auth_path: path}
  end

  @doc """
  Sets the login credentials for this client.

  ## Examples 

  ```
  vault = Vault.set_credentials(vault, %{username: "UserN4me", password: "P@55w0rd"})
  ```
  """
  @spec set_credentials(t, map) :: t
  def set_credentials(%__MODULE__{} = vault, creds) when is_map(creds) do
    %{vault | credentials: creds}
  end

  @doc """
  Authenticate against the configured auth backend.

  ## Examples

  A successful authentication returns a client containing a valid token, as well as the 
  expiration time for the token. Perform this operation before reading or 
  writing secrets.

  Errors from vault are returned as a list of strings.

  Uses pre-configured credentials if provided. Passed in credentials will
  override existing credentials. 
  ```
  {:ok, vault} = Vault.set_credentials(vault, %{username: "UserN4me", password: "P@55w0rd"})

  {:error, ["Missing Credentials, username and password are required"]} = Vault.set_credentials(vault, %{username: "whoops"})
  ```
  """
  @spec auth(t, map) :: {:ok, t} | {:error, [term]}
  def auth(vault, params \\ %{})
  def auth(%__MODULE__{auth: _, http: nil}, _params), do: {:error, ["http client not set"]}
  def auth(%__MODULE__{auth: nil, http: _}, _params), do: {:error, ["auth client not set"]}

  def auth(%__MODULE__{auth: auth, credentials: creds} = vault, params) do
    new_creds = if is_map(creds), do: Map.merge(creds, params), else: params

    case auth.login(vault, new_creds) do
      {:ok, token, ttl} ->
        expires_at = NaiveDateTime.utc_now() |> NaiveDateTime.add(ttl, :second)

        {:ok,
         %{
           vault
           | token: token,
             token_expires_at: expires_at,
             credentials: new_creds
         }}

      {:error, _reason} = otherwise ->
        otherwise
    end
  end

  @doc """
  Check if the current token is still valid.

  ## Examples

  Returns true if the current time is later than the expiration date, otherwise false.

  ```
  true = Vault.token_expired?(vault)
  ```

  """
  @spec token_expired?(t) :: true | false
  def token_expired?(%__MODULE__{token_expires_at: nil}), do: true

  def token_expired?(%__MODULE__{token_expires_at: expires_at}) do
    case NaiveDateTime.compare(expires_at, NaiveDateTime.utc_now()) do
      :lt ->
        true

      _ ->
        false
    end
  end

  @doc """
  Get a `NaiveDateTime` struct, in UTC, for when the current token will expire.

  ## Examples

  Expiration time is generated from the current time on the current server.

  ```
  ~N[2018-11-25 16:30:30.177731] = Vault.token_expires_at(vault)
  ```
  """
  def token_expires_at(client), do: client.token_expires_at

  @doc """
  Read a secret from the configured secret engine.

  ## Examples 

  Provided adapters return the values on the `data` key from vault, if present. 
  See Secret Engine adapter details for additional configuration, such as 
  returning the full response.

  Errors from vault are returned as a list of strings.
  ```
  {:ok, %{ password: "value" }} = Vault.write(vault,"secret/path/to/read")

  {:error, ["Unauthorized"]} = Vault.read(vault,"secret/bad/path")
  ```
  """
  @spec read(t, String.t(), list()) :: {:ok, map} | {:error, term}
  def read(vault, path, options \\ [])

  def read(%__MODULE__{engine: _, http: nil}, _path, _options),
    do: {:error, ["http client not set"]}

  def read(%__MODULE__{engine: nil, http: _}, _path, _options),
    do: {:error, ["secret engine not set"]}

  def read(%__MODULE__{engine: engine} = vault, path, options) do
    engine.read(vault, String.trim_leading(path, "/"), options)
  end

  @doc """
  Write a secret to the configured secret engine. 

  ## Examples 

  Provided adapters returns the values on the `data` key from vault, if present. 
  See Secret Engine adapter details for additional configuration, such as 
  returning the full response.

  Errors from vault are returned as a list of strings.
  ```
  {:ok, %{ version: 1 }} = Vault.write(vault,"secret/path/to/write", %{ secret: "value"})

  {:error, ["Unauthorized"]} = Vault.write(vault,"secret/bad/path", %{ secret: "value"})
  ```
  """
  @spec write(t, String.t(), term, list()) :: {:ok, map} | {:error, term}
  def write(vault, path, value, options \\ [])

  def write(%__MODULE__{engine: _, http: nil}, _path, _value, _options),
    do: {:error, ["http client not set"]}

  def write(%__MODULE__{engine: nil, http: _}, _path, _value, _options),
    do: {:error, ["secret engine not set"]}

  def write(%__MODULE__{engine: engine} = vault, path, value, options) do
    case engine.write(vault, String.trim_leading(path, "/"), value, options) do
      {:ok, data} ->
        {:ok, Map.merge(%{"value" => value}, data || %{})}

      otherwise ->
        otherwise
    end
  end

  @doc """
  List secret keys available at a certain path.

  ## Examples 

  Path should end with a trailing slash. Provided adapters returns the values on
  the  `data` key from vault, if present. See Secret Engine adapter details for 
  additional configuration, such as returning the full response.

  Errors from vault are returned as a list of strings.

  ```
  {:ok, %{ "keys" => ["some/", "paths", "returned"] }} = Vault.list(vault,"secret/path/to/write")

  {:error, ["Unauthorized"]} = Vault.list(vault,"secret/bad/path/")
  ```
  """
  @spec list(t, String.t(), list()) :: {:ok, map} | {:error, term}
  def list(vault, path, options \\ [])

  def list(%__MODULE__{engine: _, http: nil}, _path, _options),
    do: {:error, ["http client not set"]}

  def list(%__MODULE__{engine: nil, http: _}, _path, _options),
    do: {:error, ["secret engine not set"]}

  def list(%__MODULE__{engine: engine} = vault, path, options) do
    engine.list(vault, String.trim_leading(path, "/"), options)
  end

  @doc """
  Delete a secret from the configured secret engine.

  ## Examples

  Returns the response from vault, which is typically an empty map. See Secret 
  Engine Adapter options for further configuration.

   ```
  {:ok, %{} }} = Vault.delete(vault,"secret/path/to/write")

  {:error, ["Key not found"]} = Vault.list(vault,"secret/bad/path/")
  ```
  """
  @spec delete(t, String.t(), list()) :: {:ok, map} | {:error, term}
  def delete(vault, path, options \\ [])

  def delete(%__MODULE__{engine: _, http: nil}, _path, _options),
    do: {:error, ["http client not set"]}

  def delete(%__MODULE__{engine: nil, http: _}, _path, _options),
    do: {:error, ["secret engine not set"]}

  def delete(%__MODULE__{engine: engine} = vault, path, options) do
    engine.delete(vault, String.trim_leading(path, "/"), options)
  end

  @doc """
  Make an HTTP request against your vault instance, with the current vault token. 

  ## Examples
  This library doesn't cover every vault API, but this can help fill some of the
  gaps, and removing some boilerplate around token management, and JSON parsing.

  It can also be handy for renewing dynamic secrets, if you're using the AWS 
  Secret backend.

  Requests can take the following options a Keyword List.

  ### options:
  - `:query_params` - a keyword list of query params for the request. Do **not** include query params on the path.
  - `:body` - Map. The body for the request
  - `:headers` - Keyword list. The headers for the request
  - `:version` - String. The vault api version - defaults to "v1"

  ### General Example
  Here's a genneric example for making a request:

  ```
  vault = Vault.new(
    http: Vault.HTTP.Tesla, 
    host: "http://localhost", 
    token: "token"
    token_expires_in: NaiveDateTime.utc_now()
  )

  Vault.request(vault, :post, "path/to/call", [ body: %{ "foo" => "bar"}])
  # POST to http://localhost/v1/path/to/call
  # with headers: {"X-Vault-Token", "token"}
  # and a JSON payload of: "{ 'foo': 'bar'}"
  ```

  ### AWS lease renewal
  A quick example of renewing a lease.
  ```
  vault = Vault.new(
    http: Vault.HTTP.Tesla, 
    host: "http://localhost", 
    token: "token"
    token_expires_in: NaiveDateTime.utc_now()
  )

  body = %{lease_id: lease, increment: increment}
  {:ok, response} = Vault.request(vault, request(:put, "sys/leases/renew", [body: body])
  ```
  """

  @methods [:get, :put, :post, :patch, :head, :delete]

  @spec request(t, method, String.t(), list) :: {:ok, term} | {:error, list()}
  def request(vault, method, path, options \\ [])

  def request(%__MODULE__{http: nil}, _method, _path, _options),
    do: {:error, ["http client not set."]}

  def request(%__MODULE__{host: nil}, _method, _path, _options),
    do: {:error, ["host not set."]}

  def request(%__MODULE__{}, method, _path, _options) when method not in @methods,
    do: {:error, ["invalid method. Must be one of: #{inspect(@methods)}"]}

  def request(%__MODULE__{} = vault, method, path, options),
    do: Vault.HTTP.request(vault, method, path, options)
end
