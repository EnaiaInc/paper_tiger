defmodule PaperTiger.UserAdapters.AutoDiscover do
  @moduledoc """
  Auto-discovers user schema patterns and extracts user information.

  Attempts to discover common patterns:
  - Email: `email`, `email_address`, or follows `primary_email_id` FK
  - Name: `name`, `full_name`, or `first_name + last_name`
  - User table: `users` or `user`

  If schema cannot be discovered, returns an error instructing the user
  to implement a custom UserAdapter.
  """

  @behaviour PaperTiger.UserAdapter

  @impl true
  def get_user_info(repo, user_id) do
    with {:ok, user_table} <- discover_user_table(repo),
         {:ok, user_data} <- fetch_user(repo, user_table, user_id),
         {:ok, email} <- extract_email(repo, user_data),
         {:ok, name} <- extract_name(user_data) do
      {:ok, %{email: email, name: name}}
    else
      {:error, :no_user_table} ->
        error_message(:no_user_table)

      {:error, :user_not_found} ->
        {:error, :user_not_found}

      {:error, reason} ->
        error_message(reason)
    end
  end

  ## Discovery Functions

  defp discover_user_table(repo) do
    # Try common table names
    tables = ["users", "user"]

    case Enum.find(tables, &table_exists?(repo, &1)) do
      nil -> {:error, :no_user_table}
      table -> {:ok, table}
    end
  end

  defp table_exists?(repo, table_name) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_name = $1
    )
    """

    case repo.query(query, [table_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp fetch_user(repo, table, user_id) do
    query = "SELECT * FROM #{table} WHERE id = $1 LIMIT 1"

    case repo.query(query, [user_id]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        user_data = Enum.zip(columns, row) |> Map.new()
        {:ok, user_data}

      {:ok, %{rows: []}} ->
        {:error, :user_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_email(repo, user_data) do
    cond do
      # Direct email fields
      email = user_data["email"] ->
        {:ok, email}

      email = user_data["email_address"] ->
        {:ok, email}

      # Follow FK to emails table (like Enaia)
      email_id = user_data["primary_email_id"] ->
        case fetch_email_from_table(repo, email_id) do
          {:ok, email} -> {:ok, email}
          {:error, _} -> {:error, :no_email_field}
        end

      true ->
        {:error, :no_email_field}
    end
  end

  defp fetch_email_from_table(repo, email_id) do
    query = "SELECT address FROM emails WHERE id = $1 LIMIT 1"

    case repo.query(query, [email_id]) do
      {:ok, %{rows: [[address]]}} -> {:ok, address}
      {:ok, %{rows: []}} -> {:error, :email_not_found}
      {:error, _} -> {:error, :no_emails_table}
    end
  end

  defp extract_name(user_data) do
    cond do
      # Single name field
      name = user_data["name"] ->
        {:ok, name}

      name = user_data["full_name"] ->
        {:ok, name}

      # Split name fields
      user_data["first_name"] && user_data["last_name"] ->
        first = user_data["first_name"]
        last = user_data["last_name"]
        {:ok, "#{first} #{last}"}

      # No name available (optional)
      true ->
        {:ok, nil}
    end
  end

  ## Error Messages

  defp error_message(:no_user_table) do
    {:error,
     """
     PaperTiger could not auto-discover your user table schema.

     To fix this, implement a custom UserAdapter:

         defmodule MyApp.PaperTigerUserAdapter do
           @behaviour PaperTiger.UserAdapter

           @impl true
           def get_user_info(repo, user_id) do
             user = repo.get!(MyApp.User, user_id)
             {:ok, %{name: user.name, email: user.email}}
           end
         end

     Then configure it:

         config :paper_tiger, user_adapter: MyApp.PaperTigerUserAdapter

     See PaperTiger.UserAdapter documentation for more details.
     """}
  end

  defp error_message(:no_email_field) do
    {:error,
     """
     PaperTiger found your user table but could not discover the email field.

     Implement a custom UserAdapter to specify how to retrieve user information.
     See PaperTiger.UserAdapter documentation for details.
     """}
  end

  defp error_message(reason) do
    {:error, "Failed to discover user schema: #{inspect(reason)}"}
  end
end
