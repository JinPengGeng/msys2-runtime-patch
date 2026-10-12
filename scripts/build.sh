#!/usr/bin/env bash
# Build a patched msys-2.0.dll for one baseline.
# Runs inside an MSYS2 shell (see .github/workflows/build.yml).
#
# Env:
#   CYGWIN_TAG      e.g. cygwin-3.6.7
#   RUNTIME_COMMIT  exact msys2-runtime commit the shipped DLL reports
#                   (embedded via --with-msys2-runtime-commit)
#   PKGBUILD_COMMIT msys2/MSYS2-packages commit whose msys2-runtime/
#                   PKGBUILD matches the Cygwin rebase era
#   PATCH_FILE      fix patch to apply on top (repo-relative)
#   OUT_DIR         artifact output dir (default ./out)

set -euo pipefail

: "${CYGWIN_TAG:?}"
: "${RUNTIME_COMMIT:?}"
: "${PKGBUILD_COMMIT:?}"
: "${PATCH_FILE:?}"
OUT_DIR="${OUT_DIR:-out}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_PATH="${REPO_ROOT}/${PATCH_FILE}"
[ -f "$PATCH_PATH" ] || { echo "patch not found: $PATCH_PATH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "::group::Fetch PKGBUILD @ ${PKGBUILD_COMMIT}"
git clone --quiet --filter=blob:none --no-checkout \
  https://github.com/msys2/MSYS2-packages.git msp
cd msp
git -c advice.detachedHead=false checkout --quiet "$PKGBUILD_COMMIT" -- msys2-runtime
cd msys2-runtime
# sourceware git:// protocol may be blocked on some runners; keep the git
# source marker but force https transport.
sed -i "s#git://sourceware.org/git/newlib-cygwin.git#git+https://sourceware.org/git/newlib-cygwin.git#g" PKGBUILD
# 3.6.7-era sources hit -Werror on warnings newer GCC (15/16) diagnoses;
# upstream fixed these later (e.g. "cygcheck: remove an unused variable
# causing a build error with GCC 16"). Downgrade just this warning-to-error.
sed -i 's/OPTIM="-O2"/OPTIM="-O2 -Wno-error=unused-but-set-variable"/' PKGBUILD
echo "::endgroup::"

echo "::group::Fetch sources + official msys2 patch set (makepkg --nobuild)"
# --skipinteg: we intentionally rewrite msys2-runtime.commit below.
makepkg --nobuild --skipinteg --noconfirm --needed
echo "::endgroup::"

echo "::group::Pin runtime commit + apply fix patch"
# Make the built DLL report the same ProductVersion as the DLL it replaces
# (version-commit), so Apply-Patch.ps1 can fingerprint-match it.
echo -n "$RUNTIME_COMMIT" > src/msys2-runtime.commit
(
  cd src/msys2-runtime
  git apply --check "$PATCH_PATH"
  git apply "$PATCH_PATH"
  git diff --stat
)
echo "::endgroup::"

echo "::group::Build (makepkg --noextract)"
makepkg --noextract --skipinteg --noconfirm
echo "::endgroup::"

echo "::group::Extract msys-2.0.dll"
mkdir -p "${OUT_DIR}"
pkg="$(ls -1 msys2-runtime-*.pkg.tar.zst | head -n1)"
tar -xf "$pkg" -C pkgroot --strip-components=0 2>/dev/null || {
  mkdir -p pkgroot && tar -xf "$pkg" -C pkgroot
}
dll="$(find pkgroot -name 'msys-2.0.dll' | head -n1)"
[ -n "$dll" ] || { echo "msys-2.0.dll not found in package" >&2; exit 1; }
variant_name="${OUT_DIR}/$(basename "$dll")"
cp "$dll" "$variant_name"
sha256sum "$variant_name" | awk '{print $1}' > "${variant_name}.sha256"
# manifest: what this binary is, for traceability / GPL source offering
cat > "${OUT_DIR}/source-info.json" <<EOF
{
  "cygwin_tag": "${CYGWIN_TAG}",
  "runtime_commit": "${RUNTIME_COMMIT}",
  "pkgbuild_commit": "${PKGBUILD_COMMIT}",
  "patch": "${PATCH_FILE}",
  "msys2_source": "https://sourceware.org/git/newlib-cygwin.git#tag=${CYGWIN_TAG}",
  "pkgbuild": "https://github.com/msys2/MSYS2-packages/tree/${PKGBUILD_COMMIT}/msys2-runtime"
}
EOF
ls -la "${OUT_DIR}"
echo "::endgroup::"
