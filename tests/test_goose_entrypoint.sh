#!/usr/bin/env bash
# Tests for the OpenStackAssistant-to-Goose image entrypoint contract.
set -uo pipefail

_PASS=0
_FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/containers/goose/goose/openstack-goose-entrypoint.sh"
CONTAINERFILE="${SCRIPT_DIR}/containers/goose/goose/Containerfile"
TEST_DIR=""

assert() {
  local desc="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    ASSERTION FAILED: ${desc}"
  echo "      command: $*"
  return 1
}

assert_not_grep() {
  local needle="$1"
  local path="$2"
  local desc="$3"
  if grep -R -q "${needle}" "${path}"; then
    echo "    ASSERTION FAILED: ${desc}"
    return 1
  fi
}

run_test() {
  local name="$1"
  _setup_fixture

  local rc=0
  ( set -e; "${name}" ) || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  else
    echo "  FAIL  ${name}"
    ((_FAIL++))
  fi

  rm -rf "${TEST_DIR}"
}

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p \
    "${TEST_DIR}/bin" \
    "${TEST_DIR}/config/recipes" \
    "${TEST_DIR}/config/skills" \
    "${TEST_DIR}/config/hints" \
    "${TEST_DIR}/home" \
    "${TEST_DIR}/projected"

  printf 'projected-service-account-token\n' > "${TEST_DIR}/token"
  printf '%s\n' \
    'version: "1.0.0"' \
    'title: Test' \
    'description: Test recipe' \
    'prompt: Test the deployment' > "${TEST_DIR}/projected/check.yaml"
  ln -s "${TEST_DIR}/projected/check.yaml" \
    "${TEST_DIR}/config/recipes/check.yaml"
  printf '%s\n' \
    '---' \
    'name: test-skill' \
    'description: Test skill' \
    '---' > "${TEST_DIR}/projected/test-skill.md"
  ln -s "${TEST_DIR}/projected/test-skill.md" \
    "${TEST_DIR}/config/skills/test-skill.md"
  printf 'OpenStack test hints\n' > "${TEST_DIR}/config/hints/hints"

  cat > "${TEST_DIR}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_SLEEP_RECORD}"
EOF
  cat > "${TEST_DIR}/bin/goose" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TEST_GOOSE_RECORD}"
EOF
  chmod +x "${TEST_DIR}/bin/sleep" "${TEST_DIR}/bin/goose"
}

assistant_env() {
  env \
    "HOME=${TEST_DIR}/home" \
    "PATH=${TEST_DIR}/bin:${PATH}" \
    "OPENSTACK_GOOSE_BINARY=${TEST_DIR}/bin/goose" \
    "OPENSTACK_GOOSE_CONFIG_ROOT=${TEST_DIR}/config" \
    "OPENSTACK_GOOSE_MANAGED_CONFIG=${TEST_DIR}/managed/config.yaml" \
    "KUBERNETES_SERVICE_ACCOUNT_TOKEN_FILE=${TEST_DIR}/token" \
    "LIGHTSPEED_URL=https://lightspeed.example.test:8443/v1" \
    'LIGHTSPEED_MODEL=gemini/models/gemini-"flash"\test' \
    'MCP_SERVER_OpenStack=https://mcp.example.test/openstack/?quote="yes"&path=\server' \
    "TEST_SLEEP_RECORD=${TEST_DIR}/sleep.record" \
    "TEST_GOOSE_RECORD=${TEST_DIR}/goose.record" \
    "$@"
}

test_configures_assistant_and_keeps_alive() {
  assistant_env "${ENTRYPOINT}" keepalive

  local config="${TEST_DIR}/managed/config.yaml"
  local user_config="${TEST_DIR}/home/.config/goose/config.yaml"
  local provider="${TEST_DIR}/home/.config/goose/custom_providers/lightspeed.json"
  assert "keepalive invokes sleep infinity" \
    grep -qxF "infinity" "${TEST_DIR}/sleep.record"
  assert "managed configuration is generated under the managed layer" \
    test -f "${config}"
  assert "the user configuration is not created by the entrypoint" \
    test ! -e "${user_config}"
  assert "Goose provider is configured" \
    test "$(jq -r '.GOOSE_PROVIDER' "${config}")" = "lightspeed"
  assert "model survives JSON serialization" \
    test "$(jq -r '.GOOSE_MODEL' "${config}")" = \
      'gemini/models/gemini-"flash"\test'
  assert "MCP URL survives JSON serialization" \
    test "$(jq -r '.extensions.openstack.uri' "${config}")" = \
      'https://mcp.example.test/openstack/?quote="yes"&path=\server'
  assert "provider uses the Responses API" \
    test "$(jq -r '.base_path' "${provider}")" = "/v1/responses"
  assert "provider uses command authentication" \
    test "$(jq -r '.auth.command' "${provider}")" = "cat"
  assert "provider records the token path" \
    test "$(jq -r '.auth.args[0]' "${provider}")" = "${TEST_DIR}/token"
  assert_not_grep "projected-service-account-token" \
    "${TEST_DIR}/home/.config/goose" \
    "provider configuration must not contain the token value"
  assert_not_grep "projected-service-account-token" \
    "${TEST_DIR}/managed" \
    "managed configuration must not contain the token value"
  assert "recipe was copied as a regular file" \
    test -f "${TEST_DIR}/home/.config/goose/recipes/check.yaml"
  assert "recipe copy is not a symlink" \
    test ! -L "${TEST_DIR}/home/.config/goose/recipes/check.yaml"
  assert "recipe is registered as a slash command" \
    test "$(jq -r '.slash_commands[0].command' "${config}")" = "check"
  assert "skill was installed" \
    test -f "${TEST_DIR}/home/.config/goose/skills/test-skill/SKILL.md"
  assert "hints were installed" \
    grep -qxF "OpenStack test hints" "${TEST_DIR}/home/.goosehints"
}

test_archives_persisted_user_config_on_each_start() {
  local user_config="${TEST_DIR}/home/.config/goose/config.yaml"
  mkdir -p "$(dirname "${user_config}")"
  printf 'extensions:\n  todo:\n    enabled: false\n' > "${user_config}"

  assistant_env "${ENTRYPOINT}" keepalive

  assert "the persisted user configuration is removed from Goose's active path" \
    test ! -e "${user_config}"
  assert "the first user configuration is retained as a backup" \
    test "$(cat "${user_config}.backup")" = $'extensions:\n  todo:\n    enabled: false'

  printf 'extensions:\n  summon:\n    enabled: true\n' > "${user_config}"
  assistant_env "${ENTRYPOINT}" keepalive

  assert "a later user configuration is also removed from Goose's active path" \
    test ! -e "${user_config}"
  assert "an existing backup is not overwritten" \
    test "$(cat "${user_config}.backup")" = $'extensions:\n  todo:\n    enabled: false'
  assert "the later user configuration receives its own backup" \
    test "$(cat "${user_config}.backup.1")" = $'extensions:\n  summon:\n    enabled: true'
}

test_passes_explicit_arguments_to_goose() {
  env \
    "HOME=${TEST_DIR}/home" \
    "OPENSTACK_GOOSE_BINARY=${TEST_DIR}/bin/goose" \
    "TEST_GOOSE_RECORD=${TEST_DIR}/goose.record" \
    "${ENTRYPOINT}" session --name test-session

  assert "entrypoint passes all explicit arguments to Goose" \
    test "$(paste -sd ' ' "${TEST_DIR}/goose.record")" = \
      "session --name test-session"
}

test_declares_configmap_overlay_after_managed_layer() {
  assert "the ConfigMap overlay overrides the CR-managed configuration" \
    grep -qF \
      'GOOSE_ADDITIONAL_CONFIG_FILES=/tmp/openstack-goose/config.yaml:/etc/openstack-goose/config-overlay/config.yaml' \
      "${CONTAINERFILE}"
}

test_rejects_incomplete_lightspeed_configuration() {
  local output="${TEST_DIR}/output"
  if env \
    "HOME=${TEST_DIR}/home" \
    "PATH=${TEST_DIR}/bin:${PATH}" \
    "LIGHTSPEED_URL=https://lightspeed.example.test" \
    "${ENTRYPOINT}" keepalive > "${output}" 2>&1; then
    echo "    entrypoint unexpectedly accepted a missing LIGHTSPEED_MODEL"
    return 1
  fi
  assert "missing model has a clear error" \
    grep -q "LIGHTSPEED_MODEL is required" "${output}"
}

test_rejects_unsafe_mcp_url() {
  local output="${TEST_DIR}/output"
  local unsafe_url
  unsafe_url="$(printf 'https://mcp.example.test/\nnext')"
  if assistant_env \
    "MCP_SERVER_OpenStack=${unsafe_url}" \
    "${ENTRYPOINT}" keepalive > "${output}" 2>&1; then
    echo "    entrypoint unexpectedly accepted an MCP URL with a newline"
    return 1
  fi
  assert "unsafe MCP URL has a clear error" \
    grep -q "without control characters" "${output}"
}

test_appends_same_endpoint_additional_models() {
  assistant_env \
    'LIGHTSPEED_ADDITIONAL_MODELS=[{"name":"gemini/models/gemini-2.5-flash"}]' \
    "${ENTRYPOINT}" keepalive

  local provider="${TEST_DIR}/home/.config/goose/custom_providers/lightspeed.json"
  assert "primary model is preserved" \
    test "$(jq -r '.models[0].name' "${provider}")" = \
      'gemini/models/gemini-"flash"\test'
  assert "same-endpoint additional model is appended to the primary provider" \
    test "$(jq -r '.models[1].name' "${provider}")" = \
      "gemini/models/gemini-2.5-flash"
  assert "no extra provider is created for same-endpoint models" \
    test ! -f "${TEST_DIR}/home/.config/goose/custom_providers/lightspeed-1.json"
}

test_removes_stale_additional_model_providers() {
  local provider_dir="${TEST_DIR}/home/.config/goose/custom_providers"
  mkdir -p "${provider_dir}"
  printf '{}\n' > "${provider_dir}/lightspeed-1.json"
  printf '{}\n' > "${provider_dir}/lightspeed-12.json"
  printf '{}\n' > "${provider_dir}/lightspeed-custom.json"

  assistant_env "${ENTRYPOINT}" keepalive

  assert "stale numbered provider is removed" \
    test ! -f "${provider_dir}/lightspeed-1.json"
  assert "all stale numbered providers are removed" \
    test ! -f "${provider_dir}/lightspeed-12.json"
  assert "unmanaged provider is preserved" \
    test -f "${provider_dir}/lightspeed-custom.json"
}

test_creates_provider_for_distinct_endpoint_model() {
  assistant_env \
    'LIGHTSPEED_ADDITIONAL_MODELS=[{"name":"claude-opus","baseURL":"https://alt.example.test/v1"}]' \
    "${ENTRYPOINT}" keepalive

  local extra="${TEST_DIR}/home/.config/goose/custom_providers/lightspeed-1.json"
  assert "distinct-endpoint model gets its own provider file" \
    test -f "${extra}"
  assert "extra provider records the alternate base URL" \
    test "$(jq -r '.base_url' "${extra}")" = "https://alt.example.test/v1"
  assert "extra provider records the model name" \
    test "$(jq -r '.models[0].name' "${extra}")" = "claude-opus"
  assert "extra provider uses command authentication" \
    test "$(jq -r '.auth.command' "${extra}")" = "cat"
  local provider="${TEST_DIR}/home/.config/goose/custom_providers/lightspeed.json"
  assert "distinct-endpoint model is not appended to the primary provider" \
    test "$(jq '.models | length' "${provider}")" = "1"
}

test_rejects_unsafe_additional_models() {
  local output="${TEST_DIR}/output"
  if assistant_env \
    'LIGHTSPEED_ADDITIONAL_MODELS=[{"name":"bad","baseURL":"ftp://alt.example.test"}]' \
    "${ENTRYPOINT}" keepalive > "${output}" 2>&1; then
    echo "    entrypoint unexpectedly accepted a non-HTTP additional model baseURL"
    return 1
  fi
  assert "unsafe additional model has a clear error" \
    grep -q "invalid LIGHTSPEED_ADDITIONAL_MODELS" "${output}"
}

echo "OpenStack Goose entrypoint tests"
run_test test_configures_assistant_and_keeps_alive
run_test test_archives_persisted_user_config_on_each_start
run_test test_passes_explicit_arguments_to_goose
run_test test_declares_configmap_overlay_after_managed_layer
run_test test_rejects_incomplete_lightspeed_configuration
run_test test_rejects_unsafe_mcp_url
run_test test_appends_same_endpoint_additional_models
run_test test_removes_stale_additional_model_providers
run_test test_creates_provider_for_distinct_endpoint_model
run_test test_rejects_unsafe_additional_models

echo
echo "Results: ${_PASS} passed, ${_FAIL} failed"
[[ ${_FAIL} -eq 0 ]]
