#!/bin/sh
#
# Configure the Goose harness for an OpenStackAssistant pod. The operator is
# intentionally harness-agnostic: it supplies generic environment variables
# and read-only ConfigMap mounts, while this image translates them into Goose
# configuration.
set -eu

GOOSE_BINARY="${OPENSTACK_GOOSE_BINARY:-/usr/local/bin/goose}"
CONFIG_ROOT="${OPENSTACK_GOOSE_CONFIG_ROOT:-/etc/openstack-goose}"

# Goose loads config.yaml from this directory after every other configuration
# layer. A persisted file would therefore override the OpenStackAssistant CR
# and ConfigMap overlay. Archive it at startup rather than allowing a previous
# pod's interactive configuration to become deployment state.
USER_CONFIG_DIR="${HOME}/.config/goose"

# Managed, ephemeral configuration layer. Regenerated from the current pod
# environment on every start and written under /tmp so it works with an
# arbitrary OpenShift UID and never persists on the PVC. Goose loads it via
# GOOSE_ADDITIONAL_CONFIG_FILES, which is defined in the image so processes
# launched with `oc exec` inherit the same layering.
MANAGED_CONFIG="${OPENSTACK_GOOSE_MANAGED_CONFIG:-/tmp/openstack-goose/config.yaml}"
MANAGED_DIR="$(dirname "${MANAGED_CONFIG}")"

# Provider definitions are managed (regenerated every start), but Goose only
# loads custom providers from the fixed, non-layered custom_providers directory
# under the config dir, so they remain in $HOME rather than the managed layer.
# They contain no user preferences and are safe to regenerate in place.
PROVIDER_DIR="${USER_CONFIG_DIR}/custom_providers"
PROVIDER_FILE="${PROVIDER_DIR}/lightspeed.json"
TOKEN_FILE="${KUBERNETES_SERVICE_ACCOUNT_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

fatal() {
  printf 'openstack-goose-entrypoint: %s\n' "$*" >&2
  exit 1
}

archive_user_config() {
  user_config="${USER_CONFIG_DIR}/config.yaml"
  [ -f "${user_config}" ] || return 0

  # Do not overwrite an earlier backup: a user can create a new config during
  # each pod lifetime, and every version should remain recoverable on the PVC.
  backup_config="${user_config}.backup"
  backup_index=1
  while [ -e "${backup_config}" ] || [ -L "${backup_config}" ]; do
    backup_config="${user_config}.backup.${backup_index}"
    backup_index=$((backup_index + 1))
  done

  mv "${user_config}" "${backup_config}"
  chmod 0600 "${backup_config}"
  printf 'openstack-goose-entrypoint: archived user config at %s\n' "${backup_config}" >&2
}

replace_json() {
  target="$1"
  shift
  temporary="$(mktemp "${target}.tmp.XXXXXX")"
  if jq "$@" "${target}" > "${temporary}"; then
    chmod 0600 "${temporary}"
    mv -f "${temporary}" "${target}"
  else
    rm -f "${temporary}"
    return 1
  fi
}

install_recipes() {
  source_dir="${CONFIG_ROOT}/recipes"
  [ -d "${source_dir}" ] || return 0

  # Recipe files are copied into $HOME and referenced from the managed config by
  # absolute path; the slash_commands registration lives in the managed layer so
  # it is regenerated from the CR and never written into the user config.yaml.
  destination_dir="${USER_CONFIG_DIR}/recipes"
  mkdir -p "${destination_dir}"
  recipe_commands=""

  for recipe in "${source_dir}"/*; do
    [ -f "${recipe}" ] || continue
    basename="$(basename "${recipe}")"
    case "${basename}" in
      *.yaml|*.yml|*.json) ;;
      *) continue ;;
    esac

    command="${basename%.*}"
    [ -n "${command}" ] || fatal "invalid Goose recipe filename: ${basename}"
    case " ${recipe_commands} " in
      *" ${command} "*)
        fatal "duplicate Goose recipe command: ${command}"
        ;;
    esac
    recipe_commands="${recipe_commands} ${command}"

    installed_recipe="${destination_dir}/${basename}"
    rm -f "${installed_recipe}"
    cp "${recipe}" "${installed_recipe}"
    chmod 0600 "${installed_recipe}"
    # jq variables are intentionally protected from shell expansion.
    # shellcheck disable=SC2016
    replace_json "${MANAGED_CONFIG}" \
      --arg command "${command}" \
      --arg path "${installed_recipe}" \
      '.slash_commands += [{"command": $command, "recipe_path": $path}]'
  done
}

install_skills() {
  source_dir="${CONFIG_ROOT}/skills"
  [ -d "${source_dir}" ] || return 0

  destination_dir="${USER_CONFIG_DIR}/skills"
  mkdir -p "${destination_dir}"
  skill_names=""

  for skill in "${source_dir}"/*; do
    [ -f "${skill}" ] || continue
    basename="$(basename "${skill}")"
    name="${basename%.*}"
    [ -n "${name}" ] || fatal "invalid Goose skill filename: ${basename}"
    case " ${skill_names} " in
      *" ${name} "*)
        fatal "duplicate Goose skill name: ${name}"
        ;;
    esac
    skill_names="${skill_names} ${name}"

    skill_dir="${destination_dir}/${name}"
    mkdir -p "${skill_dir}"
    rm -f "${skill_dir}/SKILL.md"
    cp "${skill}" "${skill_dir}/SKILL.md"
    chmod 0600 "${skill_dir}/SKILL.md"
  done
}

install_hints() {
  hints_file="${CONFIG_ROOT}/hints/hints"
  [ -f "${hints_file}" ] || return 0

  rm -f "${HOME}/.goosehints"
  cp "${hints_file}" "${HOME}/.goosehints"
  chmod 0600 "${HOME}/.goosehints"
}

# configure_additional_models renders the models listed in the operator-provided
# LIGHTSPEED_ADDITIONAL_MODELS env var (JSON array of {name, baseURL}). Models
# that share the primary endpoint are appended to the lightspeed provider;
# models that declare a distinct baseURL get their own lightspeed-<N> provider
# so a subagent (e.g. an adversarial cross-review model) can select them.
configure_additional_models() {
  # Remove providers generated by an earlier configuration before handling the
  # current model list. This must precede the empty-list return so reducing or
  # removing additional models cannot leave stale providers available to Goose.
  for extra_provider in "${PROVIDER_DIR}"/lightspeed-*.json; do
    [ -f "${extra_provider}" ] || continue
    extra_index="${extra_provider##*/lightspeed-}"
    extra_index="${extra_index%.json}"
    case "${extra_index}" in
      ''|*[!0-9]*) continue ;;
    esac
    rm -f "${extra_provider}"
  done

  models_json="${LIGHTSPEED_ADDITIONAL_MODELS:-}"
  [ -n "${models_json}" ] || return 0
  command -v jq >/dev/null 2>&1 || fatal "jq is required to render additional models"

  printf '%s' "${models_json}" | jq -e '
    def has_control: explode | any(. < 32 or (. >= 127 and . <= 159));
    if type != "array" then
      error("LIGHTSPEED_ADDITIONAL_MODELS must be a JSON array")
    else
      all(.[];
        if (.name // "") == "" then
          error("additional model name is required")
        elif (.name | has_control) then
          error("additional model name must not contain control characters")
        elif ((.baseURL // "") != "")
             and ((.baseURL | has_control) or ((.baseURL | test("^https?://")) | not)) then
          error("additional model baseURL must be an HTTP(S) URL without control characters")
        else true end)
    end' >/dev/null 2>&1 || fatal "invalid LIGHTSPEED_ADDITIONAL_MODELS"

  # Models sharing the primary endpoint are appended to the lightspeed provider.
  same_url_models="$(printf '%s' "${models_json}" \
    | jq -c --arg url "${LIGHTSPEED_URL}" \
        '[.[] | select((.baseURL // "") == "" or (.baseURL == $url)) | {name: .name}]')"
  if [ "$(printf '%s' "${same_url_models}" | jq 'length')" -gt 0 ]; then
    # shellcheck disable=SC2016
    replace_json "${PROVIDER_FILE}" --argjson add "${same_url_models}" '.models += $add' \
      || fatal "failed to append additional models to the Lightspeed provider"
  fi

  # Models with a distinct endpoint get their own provider file.
  index=0
  printf '%s' "${models_json}" \
    | jq -c --arg url "${LIGHTSPEED_URL}" \
        '.[] | select((.baseURL // "") != "" and (.baseURL != $url))' \
    | while IFS= read -r entry; do
        index=$((index + 1))
        extra_provider="${PROVIDER_DIR}/lightspeed-${index}.json"
        extra_tmp="$(mktemp "${extra_provider}.tmp.XXXXXX")"
        if printf '%s' "${entry}" | jq \
            --arg token_file "${TOKEN_FILE}" \
            --arg pname "lightspeed-${index}" '
              {
                name: $pname,
                engine: "openai",
                display_name: $pname,
                description: "Lightspeed Stack OpenAI-compatible endpoint",
                api_key_env: "",
                base_url: .baseURL,
                base_path: "/v1/responses",
                models: [{name: .name}],
                headers: {"X-LCS-Merge-Server-Tools": "true"},
                supports_streaming: true,
                requires_auth: true,
                auth: {
                  command: "cat",
                  args: [$token_file],
                  refresh_interval: 300,
                  timeout_seconds: 10
                },
                dynamic_models: false
              }' > "${extra_tmp}"; then
          chmod 0600 "${extra_tmp}"
          mv -f "${extra_tmp}" "${extra_provider}"
        else
          rm -f "${extra_tmp}"
          fatal "failed to render additional Lightspeed provider ${index}"
        fi
      done
}

configure_assistant() {
  lightspeed_url="${LIGHTSPEED_URL:-}"
  lightspeed_model="${LIGHTSPEED_MODEL:-}"

  if [ -z "${lightspeed_url}" ] && [ -z "${lightspeed_model}" ]; then
    return 0
  fi
  [ -n "${lightspeed_url}" ] || fatal "LIGHTSPEED_URL is required when LIGHTSPEED_MODEL is set"
  [ -n "${lightspeed_model}" ] || fatal "LIGHTSPEED_MODEL is required when LIGHTSPEED_URL is set"
  command -v jq >/dev/null 2>&1 || fatal "jq is required to render Goose configuration"
  [ -r "${TOKEN_FILE}" ] || fatal "service-account token is not readable at ${TOKEN_FILE}"
  if [ -n "${SSL_CERT_FILE:-}" ] && [ ! -r "${SSL_CERT_FILE}" ]; then
    fatal "SSL_CERT_FILE is not readable at ${SSL_CERT_FILE}"
  fi

  umask 077
  # PROVIDER_DIR lives under $HOME; MANAGED_DIR is the ephemeral /tmp layer.
  mkdir -p "${PROVIDER_DIR}" "${MANAGED_DIR}"
  chmod 0700 "${MANAGED_DIR}"

  provider_tmp="$(mktemp "${PROVIDER_FILE}.tmp.XXXXXX")"
  if jq -n \
    --arg base_url "${lightspeed_url}" \
    --arg model "${lightspeed_model}" \
    --arg token_file "${TOKEN_FILE}" '
      def has_control:
        explode | any(. < 32 or (. >= 127 and . <= 159));
      if ($base_url | has_control) or ($base_url | test("^https?://") | not) then
        error("LIGHTSPEED_URL must be an HTTP(S) URL without control characters")
      elif ($model | has_control) then
        error("LIGHTSPEED_MODEL must not contain control characters")
      else
        {
          name: "lightspeed",
          engine: "openai",
          display_name: "Lightspeed",
          description: "Lightspeed Stack OpenAI-compatible endpoint",
          api_key_env: "",
          base_url: $base_url,
          base_path: "/v1/responses",
          models: [{name: $model}],
          headers: {"X-LCS-Merge-Server-Tools": "true"},
          supports_streaming: true,
          requires_auth: true,
          auth: {
            command: "cat",
            args: [$token_file],
            refresh_interval: 300,
            timeout_seconds: 10
          },
          dynamic_models: false
        }
      end
    ' > "${provider_tmp}"; then
    chmod 0600 "${provider_tmp}"
    mv -f "${provider_tmp}" "${PROVIDER_FILE}"
  else
    rm -f "${provider_tmp}"
    fatal "failed to render Lightspeed provider configuration"
  fi

  config_tmp="$(mktemp "${MANAGED_CONFIG}.tmp.XXXXXX")"
  if jq -n \
    --arg model "${lightspeed_model}" '
      def has_control:
        explode | any(. < 32 or (. >= 127 and . <= 159));
      def mcp_servers:
        $ENV
        | to_entries
        | map(select(.key | startswith("MCP_SERVER_")))
        | map({
            name: (.key | ltrimstr("MCP_SERVER_")),
            url: .value
          });

      (mcp_servers) as $servers
      | if ($servers
            | map(select((.name | test("^[A-Za-z_][A-Za-z0-9_]*$")) | not))
            | length) > 0 then
          error("MCP server environment names must use MCP_SERVER_<identifier>")
        elif ($servers
              | map(select((.url == "")
                           or (.url | has_control)
                           or ((.url | test("^https?://")) | not)))
              | length) > 0 then
          error("MCP server URLs must be non-empty HTTP(S) URLs without control characters")
        elif ([$servers[].name | ascii_downcase] | length)
             != ([$servers[].name | ascii_downcase] | unique | length) then
          error("MCP server names must be unique case-insensitively")
        else
          {
            GOOSE_PROVIDER: "lightspeed",
            GOOSE_MODEL: $model,
            GOOSE_TELEMETRY_ENABLED: false,
            GOOSE_DISABLE_KEYRING: true,
            extensions: ({
              developer: {enabled: true, type: "builtin"},
              computercontroller: {enabled: false, type: "builtin"},
              summarize: {enabled: true, type: "builtin"},
              summon: {enabled: false, type: "builtin"},
              skills: {enabled: true, type: "builtin"},
              apps: {enabled: false, type: "builtin"},
              analyze: {enabled: false, type: "builtin"},
              todo: {enabled: false, type: "builtin"},
              extensionmanager: {enabled: false, type: "builtin"},
              chatrecall: {enabled: false, type: "builtin"}
            } + (reduce $servers[] as $server ({};
              .[($server.name | ascii_downcase)] = {
                enabled: true,
                type: "streamable_http",
                name: ($server.name | ascii_downcase),
                uri: $server.url,
                description: (($server.name | ascii_downcase) + " MCP server"),
                timeout: 300
              }
            ))),
            slash_commands: []
          }
        end
    ' > "${config_tmp}"; then
    chmod 0600 "${config_tmp}"
    mv -f "${config_tmp}" "${MANAGED_CONFIG}"
  else
    rm -f "${config_tmp}"
    fatal "failed to render Goose configuration"
  fi

  configure_additional_models
  install_recipes
  install_skills
  install_hints
}

archive_user_config
configure_assistant

case "${1:-}" in
  keepalive)
    shift
    [ "$#" -eq 0 ] || fatal "keepalive does not accept arguments"
    exec sleep infinity
    ;;
  "")
    exec sleep infinity
    ;;
  *)
    exec "${GOOSE_BINARY}" "$@"
    ;;
esac
