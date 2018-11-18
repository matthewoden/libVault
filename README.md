# libvault

Highly configurable library for HashiCorp's Vault - handles authentication
for multiple backends, and reading, writing, listing, and deleting secrets
for a variety of engines.

When possible, it tries to emulate the CLI, with `read`, `write`, `list` and
`delete` methods. An additional `request` method is provided when you need
further flexibility.

## Flexibility

Hashicorp's Vault is highly configurable. Rather than cover every possible option,
this library strives to be flexible and adaptable. Auth backends, Secret
Engines, and Http clients are all replacable, and each behaviour asks for a
minimal contract.

### Http Adapters

The following http Adapters are provided:

- `Tesla` with `Vault.Http.Tesla`
  - Can be configured to use `:hackney`, `:ibrowse`, or `:httpc`

### Auth Adapters

Adapters have been provided for the following auth backends:

- [AppRole](https://www.vaultproject.io/api/auth/approle/index.html) with `Vault.Auth.Approle`
- [GitHub](https://www.vaultproject.io/api/auth/github/index.html) with `Vault.Auth.Github`
- [GoogleCloud](https://www.vaultproject.io/api/auth/gcp/index.html) with `Vault.Auth.GoogleCloud`
- [JWT](https://www.vaultproject.io/api/auth/gcp/index.html) with `Vault.Auth.JWT`
- [LDAP](https://www.vaultproject.io/api/auth/ldap/index.html) with `Vault.Auth.LDAP`
- [UserPass](https://www.vaultproject.io/api/auth/userpass/index.html) with `Vault.Auth.UserPass`
- [Token](https://www.vaultproject.io/api/auth/token/index.html#lookup-a-token-self-) with `Vault.Auth.Token`

In addition to the above, a generic backend is also provided (`Vault.Auth.Generic`).
If support for auth provider is missing, you can use this to get up and running
quickly, without writing out a full adapter.

### Secret Engines

Most of Vault's Secret Engines follow the same API. The `Vault.Engine.Generic`
adapter should handle most use cases for secret fetching.

Vault's KV version 2 broke away from the standard REST convention. So KV has been given
its own adapter:

- [Key/Value](https://www.vaultproject.io/api/secret/kv/index.html)
  - [v1](https://www.vaultproject.io/api/secret/kv/kv-v1.html) with `Vault.Engine.KVV1`
  - [v2](https://www.vaultproject.io/api/secret/kv/kv-v2.html) with `Vault.Engine.KVV1`

### Request Flexibility

The core library only handles the basics around secret fetching. If you need to
access additional API endpoints, this library also provides a `Vault.request`
method. This should allow you to tap into the full vault REST API, while still
benefiting from token control, JSON parsing, and other HTTP client nicities.

## Usage

Example usage:

```
client =
  Vault.new([
    engine: Vault.Engine.Generic,
    auth: Vault.Auth.UserPass,
    credentials: %{username: "username", password: "password"}
  ])
  |> Vault.login()

{:ok, db_pass} = Vault.read(client, "secret/path/to/password")
{:ok, aws_creds} = Vault.read(client, "secret/path/to/creds")
```

You can configure the client up front, or change configuration dynamically.

```
  client =
    Vault.new()
    |> Vault.set_auth(Vault.Auth.Approle)
    |> Vault.set_engine(Vault.Engine.KVV1)
    |> Vault.login(%{role_id: "role_id", secret_id: "secret_id"})

  {:ok, db_pass} = Vault.read(client, "secret/path/to/password")

  client = Vault.set_engine(Vault.Engine.KVV2) // switch to versioned secrets

  {:ok, db_pass} = Vault.write(client, "kv/path/to/password", %{ password: "db_pass" })
```

Roadmap:

- Add List, Delete for Secret Engines

## Testing Locally

When possible, tests run against a local vault instance. Otherwise, tests run against the Vault Spec, using bypass to test to confirm the success case, and follows vault patterns for failure.

1. Install the vault go cli https://www.vaultproject.io/downloads.html

1. In the current directory, set up a local dev server with `sh scripts/setup-local-vault`

1. Vault (at this time) can't be run in the background without a docker instace. For now, set up the local secret engine paths with `sh scripts/setup-engines.sh`

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `vault` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:vault, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/vault](https://hexdocs.pm/vault).
