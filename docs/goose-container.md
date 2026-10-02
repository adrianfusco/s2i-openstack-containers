# Goose container

This repository builds Goose as the `openstack-goose` operator utility image.
The `openstack-operator` consumes it directly; it is not an
`OpenStackVersion.spec.customContainerImages` service image and must not be
added to `containers/image-mappings.yaml`. It is built from the pinned upstream
source declared in
`containers/goose/sources.txt` and does not use OpenStack Python constraints
or lockfiles.

The image follows the project conventions while preserving the important parts
of the original CentOS Dockerfile:

- Goose CLI is built from source with Rust 1.94.1 directly on UBI 10 minimal.
- The runtime image contains the Goose binary, its shared-library dependencies,
  a minimal `vi` text editor, and pinned, checksum-verified `oc` and `kubectl`
  clients.
- The image runs as UID 1000 and makes `/home/goose` writable by OpenShift's
  arbitrary UID model through group-zero permissions.
- The image entrypoint translates the generic OpenStackAssistant environment
  and ConfigMap mounts into Goose provider, extension, recipe, skill, and hint
  configuration.

## OpenStackAssistant runtime contract

The image defaults to a long-running `keepalive` process because the operator
does not override the image command. Users start interactive or non-interactive
Goose commands with `oc exec`.

The operator-to-image interface is:

| `OpenStackAssistant` input | Pod contract | Image behavior |
| --- | --- | --- |
| `spec.lightspeedStack.baseURL` | `LIGHTSPEED_URL` | Sets the primary provider URL. |
| `spec.lightspeedStack.model` | `LIGHTSPEED_MODEL` | Selects the primary model. |
| `spec.lightspeedStack.additionalModels` | `LIGHTSPEED_ADDITIONAL_MODELS` as a JSON array of `{name, baseURL}` objects | Adds models with an empty or matching `baseURL` to the primary provider and creates a numbered `lightspeed-<N>` provider for each distinct endpoint. |
| `spec.mcpServers` | One `MCP_SERVER_<name>` variable per resolved server URL | Creates a Streamable HTTP extension. References to `OpenStackClient` resources are resolved by the operator before the pod is created. |
| `spec.caBundleSecretName` | CA bundle mount plus `SSL_CERT_FILE` | Makes the reconciled CA bundle available to Goose and its extensions. |
| `spec.storage.mountPath` | Writable volume mount plus `HOME` | Stores Goose sessions, generated providers, installed recipes and skills, archived interactive configs, and other runtime state. The generated managed configuration lives separately under `/tmp`; an active user `config.yaml` is archived at every image startup so declarative settings remain authoritative. The default is an `emptyDir` at `/home/goose`; `spec.storage.pvcName` selects an existing PVC to persist the remaining state across pod replacement. |
| `spec.extraConfig` | Read-only ConfigMap mounts at the requested paths | Supplies image-specific recipes, skills, hints, or configuration overlays. The conventional Goose paths are listed below. |
| `spec.env` | Additional container environment variables | Passes image-specific settings through unchanged. A value with the same name as an operator-generated variable overrides the generated value. |

The operator also injects `CONFIG_HASH` so ConfigMap content changes alter the
pod specification and cause a replacement. The entrypoint does not otherwise
consume that variable.

When `LIGHTSPEED_URL` and `LIGHTSPEED_MODEL` are present, the entrypoint:

- creates a `lightspeed` OpenAI-compatible provider using `/v1/responses`;
- reads the current pod ServiceAccount token through Goose's refreshable
  command authentication instead of storing the token in configuration;
- converts every `MCP_SERVER_<name>` environment variable into a Streamable
  HTTP extension;
- honors the operator-provided `SSL_CERT_FILE`; and
- consumes these optional, image-defined ConfigMap mount paths:
  `/etc/openstack-goose/recipes`, `/etc/openstack-goose/skills`, and
  `/etc/openstack-goose/hints/hints`; and
- configures Goose to load `/etc/openstack-goose/config-overlay/config.yaml`,
  when present, as a read-only configuration layer.

Projected recipe and skill files are copied into the writable Goose home as
regular files. Recipe files are also registered as slash commands using their
filename without the `.yaml`, `.yml`, or `.json` extension.

`LIGHTSPEED_ADDITIONAL_MODELS` is optional. It must contain a JSON array of
objects with a non-empty `name` and an optional HTTP(S) `baseURL`. Models that
omit `baseURL`, or use the primary `LIGHTSPEED_URL`, share the primary
`lightspeed` provider. A model with a different URL gets its own provider and
uses the same ServiceAccount-token authentication as the primary provider.

The entrypoint still passes explicit arguments to Goose, so standalone commands
such as `--version`, `--help`, and `session` continue to work. Set
`OPENSTACK_GOOSE_CONFIG_ROOT` only for testing or for an image-specific mount
layout, `OPENSTACK_GOOSE_MANAGED_CONFIG` only to relocate the managed layer
(it must stay in step with `GOOSE_ADDITIONAL_CONFIG_FILES`), and
`KUBERNETES_SERVICE_ACCOUNT_TOKEN_FILE` only when using a non-default projected
token path.

## Managed configuration and archived user configs

The entrypoint writes the generated `config.yaml` (model, provider selection,
MCP extensions, built-in extensions, and slash commands) to an ephemeral
*managed* layer at `/tmp/openstack-goose/config.yaml`, regenerated from the pod
environment on every start. The image sets `GOOSE_ADDITIONAL_CONFIG_FILES` (and
`OPENSTACK_GOOSE_MANAGED_CONFIG`) so Goose loads the generated configuration,
then the optional ConfigMap overlay; processes launched with `oc exec` inherit
the same layering. At startup, Goose's effective precedence is
`/etc/goose/config.yaml` < managed (`/tmp`) < ConfigMap overlay (`/etc`). The
`extensions` map is deep-merged, so an overlay can enable an image-default
extension without duplicating its definition.

Goose treats `$HOME/.config/goose/config.yaml` as a higher-precedence, writable
user layer. To prevent a setting left by a previous pod from overriding the CR
or ConfigMap, the entrypoint moves an existing file to
`config.yaml.backup` (using numbered suffixes if needed) before rendering the
managed layer. It does not create a replacement user config. A `goose configure`
command can create one during the current pod lifetime, but it is archived at
the next container start. With a PVC, the backups remain available for recovery
without participating in Goose configuration.

Custom provider definitions (`custom_providers/*.json`), copied recipe and skill
files, and `.goosehints` are managed but remain under `$HOME`, because Goose
loads them only from fixed, non-layered paths. They contain no user preferences
and are regenerated from the CR on every start.

## Customizing the assistant

There are two ways to customize a running assistant, and they map directly onto
the two configuration layers above:

- **Declaratively, through the `OpenStackAssistant` CR.** The operator turns CR
  fields into environment variables and read-only ConfigMap mounts. The image
  entrypoint reconciles CR fields into the *managed* layer on every start. A
  ConfigMap overlay is an explicit declarative override of that layer.
- **At runtime, through `oc exec` into the pod.** Goose CLI changes are written
  to `$HOME/.config/goose/config.yaml` and apply until the next container start.
  The entrypoint then archives that file so runtime changes cannot override the
  next declarative reconciliation.

Use the primary CR fields for model, endpoints, MCP servers, bundled recipes,
and skills. Use a ConfigMap overlay for settings the generic CRD does not model
or for deliberate declarative overrides. Runtime changes are useful for a
single pod lifetime; declare durable settings in the CR or ConfigMap.

### Model and provider (CR)

Set the primary AI backend with `spec.lightspeedStack`. Add secondary models
with `additionalModels`; a model with a distinct `baseURL` gets its own
provider (see the additional-models notes above).

```yaml
spec:
  lightspeedStack:
    baseURL: https://lightspeed-stack.openstack.svc:8443
    model: default
    additionalModels:
      - name: gemini/models/gemini-2.5-flash        # shares the primary endpoint
      - name: claude-opus
        baseURL: https://alt.example.test/v1         # gets its own provider
```

### MCP servers (CR)

Each entry in `spec.mcpServers` becomes an `MCP_SERVER_<name>` variable that the
entrypoint renders into a Streamable HTTP extension. Reference an
`OpenStackClient` with `openstackClientRef` (the operator resolves its URL) or
give an explicit `url`.

```yaml
spec:
  mcpServers:
    - name: openstack
      openstackClientRef: openstackclient
    - name: docs
      url: https://mcp.example.test/docs/
```

### Recipes, skills, hints, and configuration overlays (CR via ConfigMaps)

Project ConfigMaps at the image's conventional paths using `spec.extraConfig`.
The image consumes the following paths:

| Content | Mount path | Result |
| --- | --- | --- |
| Recipes | `/etc/openstack-goose/recipes` | Copied into `$HOME` and registered as `slash_commands` (command = filename without extension). |
| Skills | `/etc/openstack-goose/skills` | Installed as `$HOME/.config/goose/skills/<name>/SKILL.md`. |
| Hints | `/etc/openstack-goose/hints/hints` | Installed as `$HOME/.goosehints`. |
| Config overlay | `/etc/openstack-goose/config-overlay` | Its `config.yaml` key is loaded as a read-only Goose configuration layer above CR-managed settings. A user config created during the pod lifetime can temporarily override it, but is archived on the next container start. |

```yaml
spec:
  extraConfig:
    - name: openstackassistant-upgrade-recipes
      mountPath: /etc/openstack-goose/recipes
```

Because these are managed, they are refreshed from the ConfigMaps on every
start; edit the ConfigMap (not the copies in `$HOME`) to change them.

To declaratively set Goose options that are not modeled by the generic CRD,
mount a ConfigMap containing a `config.yaml` key at the config-overlay path:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openstackassistant-goose-config
data:
  config.yaml: |
    GOOSE_MODE: smart_approve
    GOOSE_TELEMETRY_ENABLED: false
---
apiVersion: assistant.openstack.org/v1beta1
kind: OpenStackAssistant
metadata:
  name: example
spec:
  extraConfig:
    - name: openstackassistant-goose-config
      mountPath: /etc/openstack-goose/config-overlay
```

The overlay is standard YAML and is read directly by Goose; it is not copied
into `$HOME`. It may add settings and extensions that the CRD does not model.
On conflicts, the ConfigMap wins over values generated from
`spec.lightspeedStack` and `spec.mcpServers`. An interactive user's
`$HOME/.config/goose/config.yaml` can override both until the next container
start, when the entrypoint archives it. Do not mount a ConfigMap at
`$HOME/.config/goose`: that directory must stay writable for `goose configure`
and backup creation.

### Extra environment variables (CR)

`spec.env` is passed through unchanged. A value with the same name as an
operator-generated variable overrides the generated one, so you can set Goose
tunables directly:

```yaml
spec:
  env:
    - name: GOOSE_MODE
      value: smart_approve
```

### Runtime changes and persistence (`oc exec`)

The operator runs the assistant as a single Pod named after the
`OpenStackAssistant` (also reported in `status.podName`). Exec into it to run
Goose interactively or to change preferences:

```console
oc exec -it <assistant-name> -- goose session       # start a session
oc exec -it <assistant-name> -- goose configure      # e.g. "Toggle Extensions"
```

The Pod is replaced whenever a CR change alters its spec (a new image, MCP
server, `extraConfig` mount, or `CONFIG_HASH`). That is the "pod replacement"
the persistence table below refers to.

What persists depends on storage:

| State | With `spec.storage.pvcName` | Without a PVC (`emptyDir`) |
| --- | --- | --- |
| User `config.yaml` (e.g. extension enablement) | Archived on every container start; backups persist | Archived on every container start; backups disappear when the Pod is replaced |
| Goose sessions and other `$HOME` state | Persists | Ephemeral |
| Managed `config.yaml`, providers, recipes, skills, hints | Regenerated from the CR every start | Regenerated from the CR every start |

```yaml
spec:
  storage:
    pvcName: openstack-assistant-home
```

Because the managed layer is regenerated every start and any previous user
layer is archived first, CR and ConfigMap changes always take effect on the next
pod. A user-config backup is retained only for recovery; it is not reapplied.

### Rebuilding the image

For changes that cannot be expressed through the CR (a different Goose version,
new baked-in defaults, or entrypoint behavior), edit
`containers/goose/goose/openstack-goose-entrypoint.sh` or the `Containerfile`
and rebuild (see [Build locally](#build-locally)). Point
`spec.containerImage` at your rebuilt image.

## Build locally

Install the host prerequisites if necessary:

```console
./build.sh install-deps
```

Build Goose:

```console
STREAM=master ./build.sh build goose/goose
```

The resulting image is:

```text
localhost/openstack/openstack-goose:master-latest
```

`build.sh` clones the exact Goose source commit for the build and removes that
temporary checkout when it exits. It also downloads the pinned Rust toolchain
and OpenShift client artifacts listed in `containers/goose/goose/artifacts.txt`.
The Containerfile installs the matching Rust archive locally, so it makes no
compiler download during the image build.

## Prefetch Cargo dependencies

Populate the repository's shared temporary Cargo cache before building:

```console
STREAM=master ./build.sh prefetch-cargo goose/goose
```

The command uses the pinned Goose source and its `Cargo.lock`, storing registry
crates and Git dependencies in `.tmp/cargo-home/goose/goose/`. A normal build
mounts and reuses this cache while still being allowed to download a missing
input.
Require a fully cached Cargo build with:

```console
CARGO_NET_OFFLINE=true STREAM=master ./build.sh build goose/goose
```

`.tmp/` is already ignored by Git. Remove `.tmp/cargo-home/` to discard every
Cargo cache, or refresh this cache whenever the Goose source pin or `Cargo.lock`
changes.

## Test locally

Confirm that the image starts and contains Goose:

```console
podman run --rm localhost/openstack/openstack-goose:master-latest --version
podman run --rm localhost/openstack/openstack-goose:master-latest --help
```

Confirm that the image's default process remains running:

```console
podman run --rm localhost/openstack/openstack-goose:master-latest
```

Run an interactive session against a working tree:

```console
podman run --rm -it \
  -v "$PWD:/workspace:Z" \
  -w /workspace \
  -e GOOSE_PROVIDER=openai \
  -e GOOSE_MODEL=<model> \
  -e OPENAI_API_KEY \
  localhost/openstack/openstack-goose:master-latest session
```

Goose provider credentials are intentionally passed at runtime rather than
baked into the image. The OpenStackAssistant entrypoint archives an active user
`config.yaml` at startup so mounted configuration cannot override the CR or
ConfigMap; a persistent `/home/goose` still retains sessions and archived files.

## Repository validation

Run the normal repository checks after modifying this target:

```console
tox -e test
tox -e linters
STREAM=master ./build.sh update-lockfiles goose
```

The last command regenerates `containers/goose/rpms.in.yaml`; it correctly
skips Python lockfile generation because Goose is a source-only Rust project.
