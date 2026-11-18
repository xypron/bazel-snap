#!/bin/bash
# Build Bazel 7.x from the source distribution (no Bazel needed).
#
# Usage: bootstrap.sh [version [workdir]]
#   version  default 7.7.2
#   workdir  default $HOME/bazel-build
# Environment:
#   JAVA_HOME          default /usr/lib/jvm/java-21-openjdk-<debian arch>
#   PATCH_ONLY=1       stop after patching the sources (no compiler needed)
#   DIST_ZIP           use this dist zip instead of downloading it
#
# Needs: openjdk-21-jdk-headless build-essential zip unzip python3 patch
# Result: <workdir>/src/output/bazel
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$HERE/../patches"
VERSION="${1:-7.7.2}"
WORKDIR="${2:-$HOME/bazel-build}"

case "$(uname -m)" in
x86_64) DEB_ARCH=amd64 ;;
aarch64) DEB_ARCH=arm64 ;;
riscv64) DEB_ARCH=riscv64 ;;
*) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-$DEB_ARCH}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
ZIP="${DIST_ZIP:-bazel-$VERSION-dist.zip}"
[ -f "$ZIP" ] || curl -fsSL -O \
  "https://github.com/bazelbuild/bazel/releases/download/$VERSION/bazel-$VERSION-dist.zip"
sha256sum "$ZIP"
rm -rf src
mkdir src
(cd src && unzip -q "$ZIP" 2>/dev/null || unzip -q "../$ZIP")
cd src

# 1. rules_java 7.6.5 has ":include/linux" for riscv64 (stray colon), so
#    jni_md.h is not found. Harmless on other architectures.
# 2. abseil-cpp 20230125.1 uses rdcycle on riscv64, which is privileged
#    since Linux 6.6 (SIGILL). Upstream abseil commit 7335a36d0b5c removes
#    the riscv unscaledcycleclock.
cp "$PATCHES/rules_java_riscv64_jni.patch" third_party/
cp "$PATCHES/abseil-remove-riscv-cycleclock.patch" \
  third_party/abseil_riscv64_cycleclock.patch
python3 - <<'PY'
p = "MODULE.bazel"
s = open(p).read()
old = 'single_version_override(\n    module_name = "rules_jvm_external",'
new = (
    'single_version_override(\n    module_name = "rules_java",\n'
    '    patch_strip = 1,\n'
    '    patches = ["//third_party:rules_java_riscv64_jni.patch"],\n)\n\n'
    'single_version_override(\n    module_name = "abseil-cpp",\n'
    '    patch_strip = 1,\n'
    '    patches = ["//third_party:abseil_riscv64_cycleclock.patch"],\n)\n\n')
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new + old, 1))
p = "BUILD"
s = open(p).read()
old = '        "//third_party:rules_jvm_external_6.0.patch",\n'
assert s.count(old) == 1
new = (old + '        "//third_party:rules_java_riscv64_jni.patch",\n'
       '        "//third_party:abseil_riscv64_cycleclock.patch",\n')
open(p, "w").write(s.replace(old, new, 1))
PY
echo "sources patched"
[ -z "${PATCH_ONLY:-}" ] || exit 0

export PATH="$JAVA_HOME/bin:$PATH"
# The bootstrap Bazel has no version information. bazel_features then
# assumes a development version and enables the Bazel 8 global "macro"
# (https://github.com/bazelbuild/bazel/issues/27349).
export BAZEL_DEV_VERSION_OVERRIDE="$VERSION"
export EMBED_LABEL="$VERSION"
env EXTRA_BAZEL_ARGS="--tool_java_runtime_version=local_jdk" bash ./compile.sh
ls -l output/bazel
./output/bazel --version
