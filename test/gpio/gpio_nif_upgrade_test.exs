# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.NifUpgradeTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Circuits.GPIO
  alias Circuits.GPIO.Nif

  @gpiochip "gpiochip0"

  # Hot code upgrades load the NIF from a second copy of the app while the
  # current one is still loaded.
  @moduletag :tmp_dir

  setup do
    app_dir = Application.app_dir(:circuits_gpio)

    on_exit(fn ->
      load_from(app_dir)
      :code.purge(Nif)
    end)

    %{app_dir: app_dir}
  end

  test "open GPIOs keep working after an upgrade", %{app_dir: app_dir, tmp_dir: tmp_dir} do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)
    {:ok, ref} = GPIO.subscribe(gpio1)

    assert {:module, Nif} == load_from(copy_app(app_dir, tmp_dir))
    :code.purge(Nif)

    assert GPIO.backend_info().pins_open == 2

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

    assert :ok = GPIO.force_close({@gpiochip, 0})
    assert GPIO.backend_info().pins_open == 1

    assert :ok = GPIO.close(gpio0)
    assert :ok = GPIO.close(gpio1)
  end

  test "upgrade is refused when the ABI differs", %{app_dir: app_dir, tmp_dir: tmp_dir} do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)
    {:ok, ref} = GPIO.subscribe(gpio1)

    new_app_dir = copy_app(app_dir, tmp_dir)
    nif_path = Path.join(new_app_dir, "priv/gpio_nif.so")
    nif = File.read!(nif_path) |> String.replace("gpio_nif_abi_", "gpio_nif_xyz_")
    File.write!(nif_path, nif)

    capture_log(fn -> assert {:error, :on_load_failure} == load_from(new_app_dir) end)

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

    assert :ok = GPIO.close(gpio0)
    assert :ok = GPIO.close(gpio1)
  end

  defp copy_app(app_dir, tmp_dir) do
    new_app_dir = Path.join(tmp_dir, "circuits_gpio")
    File.cp_r!(app_dir, new_app_dir)
    new_app_dir
  end

  defp load_from(app_dir) do
    true = :code.replace_path(:circuits_gpio, String.to_charlist(Path.join(app_dir, "ebin")))
    :code.purge(Nif)
    :code.load_file(Nif)
  end
end
