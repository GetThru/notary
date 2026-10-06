defmodule Outlaw.Tools do
  @moduledoc "Locates, installs and validates Java and the pinned TLA+ tools jar."

  alias Outlaw.{Config, Error}

  @spec ensure_ready() :: {:ok, %{java: String.t(), jar: String.t()}} | {:error, Error.t()}
  def ensure_ready do
    with {:ok, java} <- find_java(), {:ok, jar} <- find_jar(), do: {:ok, %{java: java, jar: jar}}
  end

  @spec find_java() :: {:ok, String.t()} | {:error, Error.t()}
  def find_java do
    java = Config.get(:java)

    case System.find_executable(java) do
      nil ->
        {:error,
         Error.new(
           :java_not_found,
           "Java was not found (looked for #{inspect(java)}). Install a JDK >= 11 " <>
             "(the Outlaw nix flake provides one: `nix develop`) or set `config :outlaw, java: \"/path/to/java\"`."
         )}

      path ->
        {output, _} = System.cmd(path, ["-version"], stderr_to_stdout: true)

        case java_major_version(output) do
          version when is_integer(version) and version >= 11 ->
            {:ok, path}

          version ->
            {:error,
             Error.new(
               :java_too_old,
               "TLC needs Java >= 11, found #{inspect(version)} at #{path}."
             )}
        end
    end
  end

  @spec find_jar() :: {:ok, String.t()} | {:error, Error.t()}
  def find_jar do
    jar = Config.jar_path()

    if File.exists?(jar),
      do: {:ok, jar},
      else:
        {:error,
         Error.new(:jar_not_found, "tla2tools.jar not found at #{jar}. Run `mix outlaw.install`.")}
  end

  @spec install(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def install(opts \\ []) do
    dest = Config.jar_path()
    sha = Keyword.get(opts, :sha256, Config.jar_sha256())
    url = Keyword.get(opts, :url, Config.jar_url())

    if File.exists?(dest) and sha256_file(dest) == sha and not Keyword.get(opts, :force, false) do
      {:ok, dest}
    else
      with {:ok, body} <- download(url), :ok <- verify(body, sha) do
        File.mkdir_p!(Path.dirname(dest))

        # Atomic (tmp + rename): a crash mid-write must never leave a
        # truncated jar at the live path, which `find_jar/0` (existence-only
        # check) would then happily serve to every TLC run.
        tmp = dest <> ".tmp#{System.unique_integer([:positive])}"
        File.write!(tmp, body)
        File.rename!(tmp, dest)
        {:ok, dest}
      end
    end
  end

  @spec java_major_version(String.t()) :: integer() | nil
  def java_major_version(output) do
    case Regex.run(~r/version "(\d+)(?:\.(\d+))?/, output) do
      [_, "1", minor] -> String.to_integer(minor)
      [_, major | _] -> String.to_integer(major)
      nil -> nil
    end
  end

  @spec sha256_file(String.t()) :: String.t()
  def sha256_file(path), do: path |> File.read!() |> sha256()

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp verify(body, expected) do
    case sha256(body) do
      ^expected ->
        :ok

      actual ->
        {:error,
         Error.new(
           :checksum_mismatch,
           "Checksum mismatch for tla2tools.jar: expected #{expected}, got #{actual}."
         )}
    end
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [ssl: ssl, autoredirect: true, timeout: 120_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, Error.new(:download_failed, "Downloading #{url} failed with HTTP #{status}.")}

      {:error, reason} ->
        {:error, Error.new(:download_failed, "Downloading #{url} failed: #{inspect(reason)}")}
    end
  end
end
