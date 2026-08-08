export image_name := env("IMAGE_NAME", "emryk-ml")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b")

[private]
default:
    @just --list

# Build the NVIDIA workstation image.
[group('build')]
build target_image=image_name tag=default_tag:
    podman build --pull=newer --target nvidia --tag "{{ target_image }}:{{ tag }}" .

# Build the Intel workstation image without NVIDIA packages or module policy.
[group('build')]
build-intel target_image=(image_name + "-intel") tag=default_tag:
    podman build --pull=newer --target intel --tag "{{ target_image }}:{{ tag }}" .

# Build an AMD64 QCOW2 from an existing bootc image reference.
[group('disk')]
build-qcow2 source=("ghcr.io/rhuze-emryk/" + image_name + ":" + default_tag):
    #!/usr/bin/env bash
    set -euo pipefail
    [[ $(uname -m) == x86_64 ]] || {
        echo >&2 "QCOW2 builds are supported on AMD64 hosts only."
        exit 1
    }

    build_dir=$(mktemp -d "${PWD}/.bib-output.XXXXXXXX")
    cleanup() {
        sudo rm -rf -- "$build_dir"
    }
    trap cleanup EXIT

    bib_args=(
        --type qcow2
        --use-librepo=True
        --rootfs btrfs
        "{{ source }}"
    )
    podman_args=(
        run
        --rm
        --privileged
        --pull=newer
        --net=host
        --security-opt label=type:unconfined_t
        --volume "${PWD}/disk_config/disk.toml:/config.toml:ro"
        --volume "${build_dir}:/output"
        --volume /var/lib/containers/storage:/var/lib/containers/storage
        "{{ bib_image }}"
    )
    sudo podman "${podman_args[@]}" "${bib_args[@]}"

    mkdir -p output
    sudo rm -rf -- "${PWD}/output/qcow2"
    sudo mv "${build_dir}/qcow2" "${PWD}/output/qcow2"
    sudo chown -R "$(id -u):$(id -g)" "${PWD}/output/qcow2"

# Rebuild a local variant rootfully, then turn that exact local image into QCOW2.
[group('disk')]
rebuild-qcow2 variant="nvidia" tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ variant }}" in
        nvidia) local_name="{{ image_name }}" ;;
        intel) local_name="{{ image_name }}-intel" ;;
        *)
            echo >&2 "variant must be 'nvidia' or 'intel'"
            exit 2
            ;;
    esac
    sudo podman build --pull=newer --target "{{ variant }}" \
        --tag "localhost/${local_name}:{{ tag }}" .
    just build-qcow2 "localhost/${local_name}:{{ tag }}"

# Run repository-local static smoke tests (no image build).
[group('test')]
local-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    for test_script in tests/test-*.sh; do
        "$test_script"
    done

# Syntax, policy, and shell checks used by CI.
[group('test')]
check: lint local-smoke
    just --unstable --fmt --check
    jq empty build_files/containers-policy.json tests/boot-smoke-config.json renovate.json
    gpg --batch --show-keys build_files/tailscale-repo.gpg >/dev/null
    if command -v taplo >/dev/null; then taplo check; fi
    if command -v actionlint >/dev/null; then actionlint; fi

[group('test')]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -d '' scripts < <(find build_files scripts tests -type f -name '*.sh' -print0)
    printf '%s\0' "${scripts[@]}" | xargs -0 -r -n1 bash -n
    printf '%s\0' "${scripts[@]}" | xargs -0 -r shellcheck

[group('test')]
format:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -d '' scripts < <(find build_files scripts tests -type f -name '*.sh' -print0)
    shfmt --write "${scripts[@]}"
    just --unstable --fmt

# Remove only generated QCOW2 output and interrupted BIB scratch directories.
[group('utility')]
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo rm -rf -- "${PWD}/output/qcow2"
    find "$PWD" -maxdepth 1 -type d -name '.bib-output.*' -exec sudo rm -rf -- {} +
