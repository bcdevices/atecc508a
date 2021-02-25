defmodule ATECC508A.Transport.I2CServer do
  use GenServer
  require Logger

  alias ATECC508A.Transport.Cache

  @moduledoc false

  # 1.5 ms in the datasheet
  @atecc508a_wake_delay_ms 2
  @atecc508a_signature <<0x04, 0x11, 0x33, 0x43>>
  @atecc508a_poll_interval_ms 2
  @atecc508a_retry_wakeup_ms 500
  @atecc508a_default_wakeup_retries 4
  @atecc508a_wake <<0>>

  @spec start_link(keyword()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link([bus_name, address, process_name]) do
    GenServer.start_link(__MODULE__, [bus_name, address], name: process_name)
  end

  @doc """
  Returns true if an ATECC508A/608A is present
  """
  @spec detected?(GenServer.server()) :: boolean()
  def detected?(server) do
    GenServer.call(server, :detected?)
  end

  @doc """
  Send a request to the ATECC508A/608A
  """
  @spec request(GenServer.server(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:error, atom()} | {:ok, binary()}
  def request(server, payload, timeout, response_payload_len) do
    GenServer.call(server, {:request, payload, timeout, response_payload_len})
  end

  @doc """
  Returns information about the transport
  """
  @spec info(GenServer.server()) :: map()
  def info(server) do
    GenServer.call(server, :info)
  end

  @impl true
  def init([bus_name, address]) do
    {:ok, i2c} = Circuits.I2C.open(bus_name)

    state = %{i2c: i2c, bus_name: bus_name, address: address, cache: Cache.init()}
    {:ok, state}
  end

  @impl true
  def handle_call(:detected?, _from, state) do
    case wakeup(state.i2c, state.address) do
      :ok ->
        {:reply, true, state}

      _ ->
        {:reply, false, state}
    end
  end

  @impl true
  def handle_call({:request, payload, timeout, response_payload_len}, _from, state) do
    case Cache.get(state.cache, payload) do
      nil ->
        case make_request(state, payload, timeout, response_payload_len) do
          {:ok, _message} = rc ->
            new_cache = Cache.put(state.cache, payload, rc)
            {:reply, rc, %{state | cache: new_cache}}

          error ->
            {:reply, error, state}
        end

      response ->
        {:reply, response, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{type: ATECC508A.Transport.I2C, bus_name: state.bus_name, address: state.address}
    {:reply, info, state}
  end

  @doc """
  Package up a request for transmission over I2C
  """
  @spec package(binary()) :: iolist()
  def package(request) do
    len = byte_size(request) + 3
    crc = ATECC508A.CRC.crc(<<len, request::binary>>)
    [3, len, request, crc]
  end

  @doc """
  Extract the response from the data returned from an I2C read
  """
  @spec unpackage(binary()) :: {:ok, binary()} | {:error, atom()}
  def unpackage(<<length, payload_and_crc::binary>>) do
    with {:ok, payload, crc} <- extract_payload(length - 3, payload_and_crc),
         ^crc <- ATECC508A.CRC.crc(<<length, payload::binary>>) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_crc}
    end
  end

  defp make_request(state, payload, timeout, response_payload_len) do
    to_send = package(payload)
    response_len = response_payload_len + 3

    min_timeout = round(timeout / 2)

    rc =
      with :ok <- wakeup(state.i2c, state.address),
           :ok <- Circuits.I2C.write(state.i2c, state.address, to_send),
           Process.sleep(min_timeout),
           {:ok, response} <-
             poll_read(state.i2c, state.address, response_len, min_timeout, timeout) do
        unpackage(response)
      else
        error ->
          _ =
            Logger.error(
              "ATECC508A: Request failed: #{inspect(to_send, binaries: :as_binaries)}, #{timeout} ms -> #{
                inspect(error)
              }"
            )

          error
      end

    rc
  end

  defp extract_payload(payload_length, payload_and_crc) do
    try do
      <<payload::binary-size(payload_length), crc::binary-size(2), _extra::binary>> =
        payload_and_crc

      {:ok, payload, crc}
    catch
      _, _ ->
        {:error, :short_packet}
    end
  end

  defp validate_signature_or_retry({:ok, @atecc508a_signature}, _retries) do
    :ok
  end

  defp validate_signature_or_retry({:ok, something_else}, retries) do
    Logger.warn(
      "Unexpected wakeup response: #{inspect(something_else)}. #{retries - 1} retries remaining."
    )

    {:retry, retries - 1}
  end

  defp validate_signature_or_retry({:error, :"Connection timed out"}, retries) do
    Logger.warn("Connection timed out. #{retries - 1} retries remaining.")

    {:retry, retries - 1}
  end

  defp validate_signature_or_retry(error, _retries) do
    Logger.error("Unexpected error response: #{inspect(error)}. ")
    error
  end

  defp wakeup(i2c, address, retries \\ @atecc508a_default_wakeup_retries)

  defp wakeup(_i2c, _address, 0) do
    {:error, :unexpected_wakeup_response}
  end

  defp wakeup(i2c, address, retries) do
    # See ATECC508A 6.1 for the wakeup sequence.
    #
    # Write to address 0 to pull SDA down for the wakeup interval (60 uS).
    # Since only 8-bits get through, the I2C speed needs to be < 133 KHz for
    # this to work. This "fails" since nobody will ACK the write and that's
    # expected.
    _ = Circuits.I2C.write(i2c, 0, @atecc508a_wake)

    # Wait for the device to wake up for real
    Process.sleep(@atecc508a_wake_delay_ms)

    # Check that it's awake by reading its signature
    case Circuits.I2C.read(i2c, address, 4)
         |> validate_signature_or_retry(retries) do
      :ok ->
        :ok

      {:retry, remaining} ->
        Process.sleep(@atecc508a_retry_wakeup_ms)
        wakeup(i2c, address, remaining)

      error ->
        error
    end
  end

  defp poll_read(i2c, address, response_len, timeout, max_timeout) do
    case Circuits.I2C.read(i2c, address, response_len) do
      {:ok, _} = response ->
        response

      {:error, :i2c_nak} ->
        new_timeout = timeout + @atecc508a_poll_interval_ms

        if new_timeout < max_timeout do
          Process.sleep(@atecc508a_poll_interval_ms)
          poll_read(i2c, address, response_len, new_timeout, max_timeout)
        else
          {:error, :timeout}
        end

      other_error ->
        other_error
    end
  end
end
