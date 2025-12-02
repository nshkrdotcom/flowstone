defmodule FlowStone.Repo do
  use Ecto.Repo,
    otp_app: :flowstone,
    adapter: Ecto.Adapters.Postgres
end
