defmodule Citadel.ContextAuthority.PolicyAuthorizer do
  @moduledoc """
  Deterministic local Context ABI authority implementation.

  This module is intentionally policy-store agnostic. Callers pass explicit
  policy facts through options so standalone tests and StackLab proof hosts do
  not need ambient app-env authority.
  """

  @behaviour Citadel.ContextAuthority.Authorizer

  alias Citadel.ContextAuthority.{AuthorityRequest, Grant}
  alias Citadel.ContractCore.CanonicalJson
  alias OuterBrain.ContextABI.{ContextPacket, Failure}

  @default_payload_modes [:refs_only, :bounded_summary, :claim_check]
  @default_operations [:context_access, :route_policy, :promotion, :rollback]
  @default_minimum_redaction_class :public_safe
  @redaction_rank %{
    public_safe: 0,
    operator_summary: 1,
    tenant_sensitive: 2,
    secret: 3
  }
  @default_denied_trust_classes [
    :model_generated_unverified,
    :memory_candidate,
    :external_untrusted
  ]
  @grant_ttl_seconds 300

  @impl true
  def authorize(packet, request, opts \\ [])

  def authorize(%ContextPacket{} = packet, request, opts) when is_list(opts) do
    request = AuthorityRequest.new!(request)

    with :ok <- ensure_packet_match(packet, request),
         {:ok, model_classes} <- allowed_model_classes(packet, request, opts),
         :ok <- ensure_route_policy(packet, request, opts),
         :ok <- ensure_payload_mode(request, opts),
         :ok <- ensure_trust_classes(request, opts),
         :ok <- ensure_redaction_class(request, opts),
         :ok <- ensure_operation(request, opts),
         :ok <- ensure_operation_evidence(request),
         :ok <- ensure_evidence_verified(request, opts),
         :ok <- ensure_fresh_policy(request, opts) do
      {:ok, build_grant(packet, request, model_classes, opts)}
    end
  rescue
    error in ArgumentError ->
      failure(:invalid_request, Exception.message(error), trace_ref(request))
  end

  def authorize(_packet, request, _opts) do
    failure(:invalid_request, "context authority requires a ContextPacket", trace_ref(request))
  end

  defp ensure_packet_match(%ContextPacket{} = packet, %AuthorityRequest{} = request) do
    cond do
      packet.tenant_ref != request.tenant_ref ->
        failure(
          :tenant_mismatch,
          "context packet tenant does not match authority request",
          request
        )

      packet.context_packet_ref != request.context_packet_ref ->
        failure(
          :packet_ref_mismatch,
          "context packet ref does not match authority request",
          request
        )

      true ->
        :ok
    end
  end

  defp allowed_model_classes(%ContextPacket{} = packet, %AuthorityRequest{} = request, opts) do
    requested = request.model_class_allowlist
    outside_packet = requested -- packet.model_class_allowlist

    cond do
      outside_packet != [] ->
        failure(
          :model_class_denied,
          "requested model class is outside the packet allowlist",
          request,
          refs("model-class", outside_packet)
        )

      true ->
        configured_allowed_model_classes(requested, request, opts)
    end
  end

  defp configured_allowed_model_classes(requested, request, opts) do
    case Keyword.get(opts, :allowed_model_classes, :any) do
      :any ->
        {:ok, requested}

      values when is_list(values) ->
        allowed = requested -- (requested -- values)

        if allowed == [] do
          failure(
            :model_class_denied,
            "no requested model class is authorized by policy",
            request,
            refs("model-class", requested)
          )
        else
          {:ok, allowed}
        end

      _other ->
        failure(:invalid_request, "allowed_model_classes must be :any or a list", request)
    end
  end

  defp ensure_route_policy(%ContextPacket{} = packet, %AuthorityRequest{} = request, opts) do
    cond do
      packet.route_policy_ref != request.route_policy_ref ->
        failure(:route_policy_denied, "route policy does not match context packet", request)

      allowed_route_policy?(request.route_policy_ref, opts) ->
        :ok

      true ->
        failure(
          :route_policy_denied,
          "route policy is not authorized by policy",
          request,
          ["route-policy://denied/#{request.route_policy_ref}"]
        )
    end
  end

  defp allowed_route_policy?(route_policy_ref, opts) do
    case Keyword.get(opts, :allowed_route_policy_refs, :any) do
      :any -> true
      values when is_list(values) -> route_policy_ref in values
      _other -> false
    end
  end

  defp ensure_payload_mode(%AuthorityRequest{} = request, opts) do
    allowed = Keyword.get(opts, :allowed_payload_modes, @default_payload_modes)

    if request.payload_mode in allowed do
      :ok
    else
      failure(
        :payload_mode_denied,
        "payload mode is not authorized for context authority",
        request,
        ["payload-mode://#{Atom.to_string(request.payload_mode)}"]
      )
    end
  end

  defp ensure_trust_classes(%AuthorityRequest{} = request, opts) do
    allowed = Keyword.get(opts, :allowed_trust_classes, default_allowed_trust_classes())
    denied = Enum.reject(request.trust_classes, &(&1 in allowed))

    if denied == [] do
      :ok
    else
      failure(
        :trust_class_denied,
        "context trust class is not authorized",
        request,
        refs("trust-class", Enum.map(denied, &Atom.to_string/1))
      )
    end
  end

  defp ensure_redaction_class(%AuthorityRequest{} = request, opts) do
    minimum = Keyword.get(opts, :minimum_redaction_class, @default_minimum_redaction_class)

    if redaction_rank(request.redaction_class) >= redaction_rank(minimum) do
      :ok
    else
      failure(
        :redaction_downgrade_denied,
        "requested redaction class is below the required minimum",
        request,
        [
          "redaction://requested/#{Atom.to_string(request.redaction_class)}",
          "redaction://minimum/#{Atom.to_string(minimum)}"
        ]
      )
    end
  end

  defp ensure_operation(%AuthorityRequest{} = request, opts) do
    allowed = Keyword.get(opts, :allowed_operations, @default_operations)

    if request.operation in allowed do
      :ok
    else
      failure(
        :operation_denied,
        "requested context authority operation is not authorized",
        request,
        ["operation://#{Atom.to_string(request.operation)}"]
      )
    end
  end

  defp ensure_operation_evidence(%AuthorityRequest{operation: :promotion} = request) do
    if Enum.any?(request.evidence_refs, &String.starts_with?(&1, "eval://")) do
      :ok
    else
      failure(
        :missing_evidence,
        "promotion authority requires eval evidence refs",
        request,
        ["operation://promotion", "evidence://eval-required"]
      )
    end
  end

  defp ensure_operation_evidence(%AuthorityRequest{operation: :rollback} = request) do
    if request.evidence_refs == [] do
      failure(
        :missing_evidence,
        "rollback authority requires rollback evidence refs",
        request,
        ["operation://rollback", "evidence://rollback-required"]
      )
    else
      :ok
    end
  end

  defp ensure_operation_evidence(%AuthorityRequest{}), do: :ok

  defp ensure_evidence_verified(%AuthorityRequest{} = request, opts) do
    case Keyword.get(opts, :evidence_resolver) do
      nil ->
        :ok

      resolver when is_function(resolver, 2) ->
        request.evidence_refs
        |> Enum.reduce_while(:ok, fn ref, :ok ->
          case resolver.(ref, request) do
            :ok -> {:cont, :ok}
            {:ok, evidence} -> evidence_tenant_matches(ref, evidence, request)
            true -> {:cont, :ok}
            _other -> {:halt, evidence_unverified(request, ref)}
          end
        end)

      _other ->
        failure(:invalid_request, "evidence_resolver must be a two-arity function", request)
    end
  end

  defp evidence_tenant_matches(ref, %{tenant_ref: tenant_ref}, %AuthorityRequest{} = request)
       when tenant_ref != request.tenant_ref do
    {:halt, evidence_unverified(request, ref)}
  end

  defp evidence_tenant_matches(ref, %{"tenant_ref" => tenant_ref}, %AuthorityRequest{} = request)
       when tenant_ref != request.tenant_ref do
    {:halt, evidence_unverified(request, ref)}
  end

  defp evidence_tenant_matches(_ref, _evidence, _request), do: {:cont, :ok}

  defp evidence_unverified(%AuthorityRequest{} = request, ref) do
    failure(:evidence_unverified, "authority evidence could not be verified", request, [ref])
  end

  defp ensure_fresh_policy(%AuthorityRequest{policy_expires_at: nil}, _opts), do: :ok

  defp ensure_fresh_policy(%AuthorityRequest{policy_expires_at: expires_at} = request, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      failure(:stale_grant, "context authority policy window is stale", request)
    end
  end

  defp build_grant(%ContextPacket{} = packet, %AuthorityRequest{} = request, model_classes, opts) do
    Grant.new!(%{
      authority_ref: request.authority_ref || authority_ref(packet, request, model_classes),
      tenant_ref: request.tenant_ref,
      allowed_model_classes: model_classes,
      route_policy_ref: request.route_policy_ref,
      expires_at: grant_expires_at(opts),
      trace_ref: request.trace_ref,
      payload_mode: request.payload_mode,
      redaction_class: request.redaction_class,
      data_use: "model_context",
      operation: request.operation,
      evidence_refs: request.evidence_refs ++ ["context-packet://hash/#{packet.packet_hash}"],
      metadata: %{
        "context_packet_ref" => packet.context_packet_ref,
        "packet_hash" => packet.packet_hash
      }
    })
  end

  defp grant_expires_at(opts) do
    cond do
      Keyword.has_key?(opts, :grant_expires_at) ->
        Keyword.fetch!(opts, :grant_expires_at)

      match?(%DateTime{}, Keyword.get(opts, :now)) ->
        opts |> Keyword.fetch!(:now) |> DateTime.add(@grant_ttl_seconds, :second)

      true ->
        nil
    end
  end

  defp authority_ref(%ContextPacket{} = packet, %AuthorityRequest{} = request, model_classes) do
    hash =
      %{
        tenant_ref: request.tenant_ref,
        actor_ref: request.actor_ref,
        context_packet_ref: packet.context_packet_ref,
        packet_hash: packet.packet_hash,
        route_policy_ref: request.route_policy_ref,
        allowed_model_classes: model_classes,
        payload_mode: request.payload_mode,
        redaction_class: request.redaction_class,
        operation: request.operation
      }
      |> CanonicalJson.encode_inline!(
        max_bytes: 256_000,
        label: "Citadel.ContextAuthority authority ref input"
      )
      |> sha256_lower_hex()

    "authority://citadel/context/#{hash}"
  end

  defp failure(reason, message, request, evidence_refs \\ []) do
    {:error,
     Failure.new!(
       owner: :citadel,
       reason_code: "citadel.authority.#{Atom.to_string(reason)}.v1",
       safe_message: message,
       retryable?: false,
       trace_ref: trace_ref(request),
       evidence_refs: evidence_refs
     )}
  end

  defp trace_ref(%AuthorityRequest{trace_ref: trace_ref}), do: trace_ref

  defp trace_ref(%{} = attrs),
    do: Map.get(attrs, :trace_ref) || Map.get(attrs, "trace_ref")

  defp trace_ref(_other), do: nil

  defp refs(prefix, values), do: Enum.map(values, &"#{prefix}://#{&1}")

  defp default_allowed_trust_classes do
    AuthorityRequest.trust_classes() -- @default_denied_trust_classes
  end

  defp redaction_rank(class), do: Map.fetch!(@redaction_rank, class)

  defp sha256_lower_hex(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
