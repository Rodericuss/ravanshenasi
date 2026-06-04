defmodule Ravanshenasi.Patients.PatientFrameworkTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Patients.PatientFramework

  test "changeset exige patient_id e thinking_framework_id" do
    cs = PatientFramework.changeset(%PatientFramework{}, %{})
    refute cs.valid?
  end
end
