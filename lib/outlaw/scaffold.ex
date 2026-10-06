defmodule Outlaw.Scaffold do
  @moduledoc "Generates the files for `mix outlaw.new`."

  @type file :: {String.t(), String.t(), :create | :create_if_missing}

  @spec files(String.t(), keyword()) :: [file()]
  def files(name, opts) do
    specs_dir = Keyword.fetch!(opts, :specs_dir)
    module = "#{Keyword.fetch!(opts, :app_module)}.Specs.#{name}"
    snake = Macro.underscore(name)
    spec_path = Path.join(specs_dir, "#{name}.tla")
    assigns = [name: name, module: module, spec_path: spec_path]

    spec_files = [
      {spec_path, render("spec.tla.eex", assigns), :create},
      {Path.join(specs_dir, "#{name}.cfg"), render("spec.cfg.eex", assigns), :create},
      {Path.join(specs_dir, "AGENTS.md"), render("AGENTS.md.eex", assigns), :create_if_missing}
    ]

    mapping_files =
      if Keyword.get(opts, :mapping, true) do
        [
          {"test/outlaw/#{snake}_spec.ex", render("mapping.ex.eex", assigns), :create_if_missing},
          {"test/outlaw/#{snake}_conformance_test.exs",
           render("conformance_test.exs.eex", assigns), :create_if_missing}
        ]
      else
        []
      end

    spec_files ++ mapping_files
  end

  @spec write([file()], String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def write(files, root \\ File.cwd!()) do
    # Never overwrites: existing files are skipped. A run that would write
    # nothing (everything already exists) fails with the existing `:create`
    # files listed -- a silent no-op success would hide "this spec already
    # exists" -- while a partial run (e.g. the documented rerun without
    # --no-mapping after --no-mapping) succeeds, writing just the missing
    # template files.
    {to_write, skipped} =
      Enum.split_with(files, fn {path, _, _} -> not File.exists?(Path.join(root, path)) end)

    case {to_write, skipped} do
      {[], _} ->
        {:error, for({path, _, :create} <- files, do: path)}

      _ ->
        written =
          Enum.map(to_write, fn {path, content, _mode} ->
            full = Path.join(root, path)
            File.mkdir_p!(Path.dirname(full))
            File.write!(full, content)
            path
          end)

        {:ok, written}
    end
  end

  @spec next_steps(String.t(), boolean()) :: String.t()
  def next_steps(name, mapping?) do
    mapping_step =
      if mapping?,
        do:
          "3. Implement it (or ask an LLM to), completing test/outlaw/#{Macro.underscore(name)}_spec.ex.\n",
        else:
          "3. When ready to implement, rerun `mix outlaw.new #{name}` (without --no-mapping) to add the mapping template files; existing files are kept.\n"

    """

    Next steps:
    1. Write the spec: specs/#{name}.tla and specs/#{name}.cfg, then `mix outlaw.check #{name}`.
    2. When you are happy with it, record it as reviewed: `mix outlaw.lock`.
    #{mapping_step}4. Verify: `mix outlaw.verify`.

    One-time setup in mix.exs (if not done yet):

        def project do
          [..., elixirc_paths: elixirc_paths(Mix.env())]
        end

        def cli, do: [preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test]]

        defp elixirc_paths(:test), do: ["lib", "test/support", "test/outlaw"]
        defp elixirc_paths(_), do: ["lib"]

    Add to your CLAUDE.md / AGENTS.md so LLM agents follow the rules:

        This project uses Outlaw (TLA+ specs in specs/). Before implementing or
        changing anything covered by a spec, read specs/AGENTS.md. Never edit
        specs; verify with `mix outlaw.verify --json`.
    """
  end

  defp render(template, assigns) do
    [:code.priv_dir(:outlaw), "templates", template]
    |> Path.join()
    |> EEx.eval_file(assigns: assigns)
  end
end
