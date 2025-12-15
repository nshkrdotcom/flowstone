defmodule FlowStone.Repo.Migrations.AddMaterializationUniqueIndex do
  use Ecto.Migration

  @doc """
  Add unique constraint on materializations to prevent duplicate entries
  for the same asset/partition/run_id combination.

  This ensures identity invariants are maintained and concurrent workers
  cannot insert duplicate records.
  """
  def change do
    # Create unique index on the identity columns
    create unique_index(:flowstone_materializations, [:asset_name, :partition, :run_id],
             name: :flowstone_materializations_identity_index
           )
  end
end
