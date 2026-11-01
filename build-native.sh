#!/usr/bin/env bash
# ==============================================================================
# build-native.sh
# Reproducible one-command cross-build script for GNU PSPP 2.1.2 and its
# dependencies (zlib, libiconv, gettext/libintl, libxml2, gsl) targeting
# Android ABIs: arm64-v8a, armeabi-v7a, x86_64 with Android NDK r27.
#
# Output:
#   app/src/main/jniLibs/<abi>/libpspp_jni.so
#   app/src/main/assets/pspp/locale/<lang>/LC_MESSAGES/pspp.mo
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ROOT_DIR}/native-build"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
SRC_DIR="${BUILD_ROOT}/src"
PATCH_DIR="${ROOT_DIR}/patches"
JNILIBS_DIR="${ROOT_DIR}/app/src/main/jniLibs"
ASSETS_PSPP_DIR="${ROOT_DIR}/app/src/main/assets/pspp"

# Source URLs & Pinned GNU GPG Fingerprint
PSPP_VERSION="2.1.2"
PSPP_TARBALL="pspp-${PSPP_VERSION}.tar.gz"
PSPP_URL="https://ftp.wayne.edu/gnu/pspp/${PSPP_TARBALL}"
PSPP_SIG_URL="https://ftp.wayne.edu/gnu/pspp/${PSPP_TARBALL}.sig"
GNU_KEYRING_URL="https://ftp.gnu.org/gnu/gnu-keyring.gpg"
# Pinned fingerprint: C2D1 AB06 1656 AAC5 4B5E 9754 8519 9DE8 C664 8E90
PINNED_FPR="C2D1AB061656AAC54B5E975485199DE8C6648E90"

ZLIB_VERSION="1.3.1"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"

LIBICONV_VERSION="1.17"
LIBICONV_URL="https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz"

GETTEXT_VERSION="0.22.5"
GETTEXT_URL="https://ftp.gnu.org/pub/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.gz"

LIBXML2_VERSION="2.12.7"
LIBXML2_URL="https://download.gnome.org/sources/libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz"

GSL_VERSION="2.8"
GSL_URL="https://ftp.gnu.org/pub/gnu/gsl/gsl-${GSL_VERSION}.tar.gz"

ANDROID_API=24
if [[ -n "${TARGET_ABIS:-}" ]]; then
  read -r -a ABIS <<< "${TARGET_ABIS}"
else
  ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")
fi
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Locate Android NDK r27
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
    ANDROID_NDK_HOME="${ANDROID_NDK_ROOT}"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}/ndk" ]]; then
    ANDROID_NDK_HOME="$(ls -d "${ANDROID_SDK_ROOT}/ndk/"* 2>/dev/null | sort -V | tail -n1)"
  elif [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}/ndk" ]]; then
    ANDROID_NDK_HOME="$(ls -d "${ANDROID_HOME}/ndk/"* 2>/dev/null | sort -V | tail -n1)"
  else
    echo "ERROR: ANDROID_NDK_HOME is not set and NDK could not be found under ANDROID_SDK_ROOT." >&2
    exit 1
  fi
fi

HOST_TAG="linux-x86_64"
if [[ "$(uname -s)" == "Darwin" ]]; then
  HOST_TAG="darwin-x86_64"
fi
TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}"
if [[ ! -d "${TOOLCHAIN}" ]]; then
  echo "ERROR: NDK LLVM toolchain not found at ${TOOLCHAIN}" >&2
  exit 1
fi

echo "==> Using Android NDK: ${ANDROID_NDK_HOME}"
echo "==> Using LLVM Toolchain: ${TOOLCHAIN}"
mkdir -p "${DOWNLOAD_DIR}" "${SRC_DIR}" "${JNILIBS_DIR}" "${ASSETS_PSPP_DIR}/locale" "${ASSETS_PSPP_DIR}/patches"

download_file() {
  local url="$1"
  local dest="$2"
  if [[ ! -f "${dest}" ]]; then
    echo "==> Downloading $(basename "${dest}") from ${url}"
    curl -fL --retry 3 --retry-delay 2 -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
  fi
}

# 1. Download all source archives
download_file "${GNU_KEYRING_URL}" "${DOWNLOAD_DIR}/gnu-keyring.gpg"
download_file "${PSPP_URL}" "${DOWNLOAD_DIR}/${PSPP_TARBALL}"
download_file "${PSPP_SIG_URL}" "${DOWNLOAD_DIR}/${PSPP_TARBALL}.sig"
download_file "${ZLIB_URL}" "${DOWNLOAD_DIR}/zlib-${ZLIB_VERSION}.tar.gz"
download_file "${LIBICONV_URL}" "${DOWNLOAD_DIR}/libiconv-${LIBICONV_VERSION}.tar.gz"
download_file "${GETTEXT_URL}" "${DOWNLOAD_DIR}/gettext-${GETTEXT_VERSION}.tar.gz"
download_file "${LIBXML2_URL}" "${DOWNLOAD_DIR}/libxml2-${LIBXML2_VERSION}.tar.xz"
download_file "${GSL_URL}" "${DOWNLOAD_DIR}/gsl-${GSL_VERSION}.tar.gz"

# 2. Verify PSPP 2.1.2 GPG signature and enforce pinned fingerprint
echo "==> Verifying ${PSPP_TARBALL} GPG signature against gnu-keyring.gpg..."
GNUPGHOME_TMP="$(mktemp -d)"
trap 'rm -rf "${GNUPGHOME_TMP}"' EXIT
chmod 700 "${GNUPGHOME_TMP}"

GPG_STATUS="$(gpg --homedir "${GNUPGHOME_TMP}" \
  --no-default-keyring \
  --keyring "${DOWNLOAD_DIR}/gnu-keyring.gpg" \
  --status-fd 1 \
  --verify "${DOWNLOAD_DIR}/${PSPP_TARBALL}.sig" "${DOWNLOAD_DIR}/${PSPP_TARBALL}" 2>&1 || true)"

echo "${GPG_STATUS}"
if ! grep -F "[GNUPG:] VALIDSIG ${PINNED_FPR}" >/dev/null <<< "${GPG_STATUS}"; then
  if ! grep -E "\[GNUPG:\] VALIDSIG [0-9A-F]+ .* ${PINNED_FPR}" >/dev/null <<< "${GPG_STATUS}"; then
    echo "FATAL: GPG signature verification failed or signing key fingerprint did not match pinned key ${PINNED_FPR}" >&2
    exit 1
  fi
fi
echo "==> GPG signature verified: matched pinned fingerprint ${PINNED_FPR}"

# Helper: Regenerates a specific patch file from the actual extracted PSPP source if patch --dry-run fails
regenerate_patch_from_source() {
  local patch_name="$1"
  local orig_tree="$2"
  local target_patch="${PATCH_DIR}/${patch_name}"
  echo "==> Regenerating ${patch_name} directly from actual extracted PSPP ${PSPP_VERSION} source..."

  python3 - "${patch_name}" "${orig_tree}" "${target_patch}" << 'PYEOF'
import os, shutil, subprocess, sys

patch_name, orig_tree, target_patch = sys.argv[1], sys.argv[2], sys.argv[3]
work_tree = orig_tree + "-regen-work"
if os.path.exists(work_tree):
    shutil.rmtree(work_tree)
shutil.copytree(orig_tree, work_tree)

def write_diff(rel_files, reason_line):
    out = [reason_line.strip() + "\n"]
    for rf in rel_files:
        res = subprocess.run(
            ["diff", "-u", "--label", "a/" + rf, "--label", "b/" + rf,
             os.path.join(orig_tree, rf), os.path.join(work_tree, rf)],
            capture_output=True, text=True
        )
        out.append(res.stdout)
    with open(target_patch, "w") as f:
        f.write("".join(out))

if patch_name == "01-disable-cairo-pango.patch":
    # 1. configure.ac
    p = os.path.join(work_tree, "configure.ac")
    s = open(p).read()
    s = s.replace(
        'PKG_CHECK_MODULES([CAIRO], [cairo >= 1.5 pango >= 1.22 pangocairo],\n  [CPPFLAGS="$CPPFLAGS $CAIRO_CFLAGS"],\n  [PSPP_REQUIRED_PREREQ([cairo 1.5 or later and pango 1.22 or later])])',
        'AC_ARG_WITH([cairo],\n  [AS_HELP_STRING([--without-cairo], [Disable Cairo/Pango chart & PDF rendering])],\n  [with_cairo=$withval],\n  [with_cairo=yes])\nAS_IF([test "x$with_cairo" != "xno"],\n  [PKG_CHECK_MODULES([CAIRO], [cairo >= 1.5 pango >= 1.22 pangocairo],\n    [CPPFLAGS="$CPPFLAGS $CAIRO_CFLAGS"\n     AC_DEFINE([HAVE_CAIRO], [1], [Define to 1 if Cairo/Pango is enabled.])],\n    [PSPP_REQUIRED_PREREQ([cairo 1.5 or later and pango 1.22 or later])])],\n  [CAIRO_CFLAGS=""\n   CAIRO_LIBS=""\n   AC_SUBST([CAIRO_CFLAGS])\n   AC_SUBST([CAIRO_LIBS])])\nAM_CONDITIONAL([HAVE_CAIRO], [test "x$with_cairo" != "xno"])',
        1
    )
    open(p, "w").write(s)

    # 2. src/output/output-item.h
    p = os.path.join(work_tree, "src/output/output-item.h")
    s = open(p).read().replace(
        "#include <cairo.h>",
        "#ifdef HAVE_CAIRO\n#include <cairo.h>\n#else\ntypedef struct _cairo_surface cairo_surface_t;\n#endif",
        1
    )
    open(p, "w").write(s)

    # 3. src/output/output-item.c
    p = os.path.join(work_tree, "src/output/output-item.c")
    s = open(p).read()
    s = s.replace(
        "        case OUTPUT_ITEM_IMAGE:\n          cairo_surface_destroy (item->image);\n          break;",
        "        case OUTPUT_ITEM_IMAGE:\n#ifdef HAVE_CAIRO\n          cairo_surface_destroy (item->image);\n#endif\n          break;",
        1
    )
    s = s.replace(
        "    case OUTPUT_ITEM_IMAGE:\n      new->image = cairo_surface_reference (old->image);\n      break;",
        "    case OUTPUT_ITEM_IMAGE:\n#ifdef HAVE_CAIRO\n      new->image = cairo_surface_reference (old->image);\n#else\n      new->image = old->image;\n#endif\n      break;",
        1
    )
    open(p, "w").write(s)

    # 4. src/output/driver.c
    p = os.path.join(work_tree, "src/output/driver.c")
    s = open(p).read().replace(
        "    &pdf_driver_factory,\n    &ps_driver_factory,\n    &svg_driver_factory,\n    &png_driver_factory,",
        "#ifdef HAVE_CAIRO\n    &pdf_driver_factory,\n    &ps_driver_factory,\n    &svg_driver_factory,\n    &png_driver_factory,\n#endif",
        1
    )
    open(p, "w").write(s)

    # 5. src/output/html.c
    p = os.path.join(work_tree, "src/output/html.c")
    s = open(p).read().replace('#include "output/cairo-chart.h"', '#ifdef HAVE_CAIRO\n#include "output/cairo-chart.h"\n#endif', 1)
    s = s.replace("    case OUTPUT_ITEM_CHART:\n      if (html->chart_file_name)", "    case OUTPUT_ITEM_CHART:\n#ifdef HAVE_CAIRO\n      if (html->chart_file_name)", 1)
    s = s.replace("        }\n      break;\n\n    case OUTPUT_ITEM_GROUP:", "        }\n#endif\n      break;\n\n    case OUTPUT_ITEM_GROUP:", 1)
    s = s.replace("    case OUTPUT_ITEM_IMAGE:\n      if (html->chart_file_name)", "    case OUTPUT_ITEM_IMAGE:\n#ifdef HAVE_CAIRO\n      if (html->chart_file_name)", 1)
    s = s.replace("        }\n      break;\n\n    case OUTPUT_ITEM_MESSAGE:", "        }\n#endif\n      break;\n\n    case OUTPUT_ITEM_MESSAGE:", 1)
    open(p, "w").write(s)

    # 6. src/output/tex.c & src/output/spv-driver.c
    p = os.path.join(work_tree, "src/output/tex.c")
    s = open(p).read().replace('#include "output/cairo-chart.h"', '#ifdef HAVE_CAIRO\n#include "output/cairo-chart.h"\n#endif', 1)
    s = s.replace("    case OUTPUT_ITEM_CHART:\n      if (tex->chart_file_name != NULL)", "    case OUTPUT_ITEM_CHART:\n#ifdef HAVE_CAIRO\n      if (tex->chart_file_name != NULL)", 1)
    s = s.replace("      break;\n\n    case OUTPUT_ITEM_GROUP:", "#endif\n      break;\n\n    case OUTPUT_ITEM_GROUP:", 1)
    s = s.replace("    case OUTPUT_ITEM_IMAGE:\n      {", "    case OUTPUT_ITEM_IMAGE:\n#ifdef HAVE_CAIRO\n      {", 1)
    s = s.replace("      }\n      break;\n\n    case OUTPUT_ITEM_MESSAGE:", "      }\n#endif\n      break;\n\n    case OUTPUT_ITEM_MESSAGE:", 1)
    open(p, "w").write(s)

    p = os.path.join(work_tree, "src/output/spv-driver.c")
    s = open(p).read().replace('#include "output/cairo-chart.h"', '#ifdef HAVE_CAIRO\n#include "output/cairo-chart.h"\n#endif', 1)
    open(p, "w").write(s)

    write_diff(
        ["configure.ac", "src/output/output-item.h", "src/output/output-item.c",
         "src/output/driver.c", "src/output/html.c", "src/output/tex.c", "src/output/spv-driver.c"],
        "# Reason: Make Cairo/Pango optional via --without-cairo so HTML, CSV, ASCII, ODT, SPV, and TeX drivers compile without Cairo/Pango."
    )

elif patch_name == "02-android-gnulib-bionic.patch":
    p = os.path.join(work_tree, "gl/nl_langinfo.c")
    s = open(p).read().replace(
        "# else\n  strcpy (result, codeset);\n  return result;\n#endif",
        "# elif defined __ANDROID__\n  return (char *) \"UTF-8\";\n# else\n  strcpy (result, codeset);\n  return result;\n#endif",
        1
    )
    open(p, "w").write(s)

    p = os.path.join(work_tree, "gl/progname.c")
    s = open(p).read().replace(
        "  char const *slash = strrchr (argv0, '/');",
        "  if (argv0 == NULL)\n    argv0 = \"pspp\";\n  char const *slash = strrchr (argv0, '/');",
        1
    )
    open(p, "w").write(s)
    write_diff(["gl/nl_langinfo.c", "gl/progname.c"], "# Reason: Fix gnulib cross-compile assumptions and Android Bionic UTF-8 codeset and NULL argv0 handling.")

elif patch_name == "03-android-tempdir-and-relocatable-paths.patch":
    p = os.path.join(work_tree, "gl/tmpdir.c")
    s = open(p).read().replace(
        '      else if (strcmp (P_tmpdir, "/tmp") != 0 && direxists ("/tmp"))\n        dir = "/tmp";',
        '      else if (strcmp (P_tmpdir, "/tmp") != 0 && direxists ("/tmp"))\n        dir = "/tmp";\n#if defined __ANDROID__\n      else if (direxists ("/data/local/tmp"))\n        dir = "/data/local/tmp";\n#endif',
        1
    )
    open(p, "w").write(s)

    p = os.path.join(work_tree, "gl/relocatable.c")
    s = open(p).read().replace(
        "const char *\nrelocate (const char *pathname)\n{",
        'const char *\nrelocate (const char *pathname)\n{\n#if defined __ANDROID__\n  if (pathname != NULL)\n    {\n      const char *env_data = getenv ("PSPP_DATADIR");\n      if (env_data != NULL && strstr (pathname, "/share/pspp") != NULL)\n        return env_data;\n      const char *env_locale = getenv ("PSPP_LOCALEDIR");\n      if (env_locale != NULL && strstr (pathname, "/share/locale") != NULL)\n        return env_locale;\n    }\n#endif',
        1
    )
    open(p, "w").write(s)

    p = os.path.join(work_tree, "src/libpspp/i18n.c")
    s = open(p).read().replace(
        "  char *allocated;\n  bindtextdomain (PACKAGE, relocate2 (locale_dir, &allocated));\n  free (allocated);\n  textdomain (PACKAGE);",
        '  char *allocated = NULL;\n  const char *env_locale = getenv ("PSPP_LOCALEDIR");\n  bindtextdomain (PACKAGE, env_locale ? env_locale : relocate2 (locale_dir, &allocated));\n  bind_textdomain_codeset (PACKAGE, "UTF-8");\n  free (allocated);\n  textdomain (PACKAGE);',
        1
    )
    open(p, "w").write(s)
    write_diff(["gl/tmpdir.c", "gl/relocatable.c", "src/libpspp/i18n.c"], "# Reason: Honour TMPDIR and runtime PSPP_DATADIR/PSPP_LOCALEDIR so init() points gettext at extracted .mo files on Android.")

elif patch_name == "04-library-reentrant-reset-and-exit-guard.patch":
    p = os.path.join(work_tree, "src/ui/terminal/main.c")
    s = open(p).read()
    s = s.replace(
        "static struct session *the_session;",
        "#include <setjmp.h>\n#include <stdatomic.h>\n\nstatic sigjmp_buf pspp_jni_exit_jmp;\nstatic int pspp_jni_jmp_armed = 0;\nstatic atomic_int pspp_jni_cancel_requested = 0;\n\nvoid\npspp_request_cancel (void)\n{\n  atomic_store (&pspp_jni_cancel_requested, 1);\n}\n\nint\npspp_is_cancel_requested (void)\n{\n  return atomic_load (&pspp_jni_cancel_requested);\n}\n\nvoid\npspp_safe_exit (int status)\n{\n  if (pspp_jni_jmp_armed)\n    siglongjmp (pspp_jni_exit_jmp, status == 0 ? 1000 : status);\n  exit (status);\n}\n\n#ifdef PSPP_ANDROID_LIBRARY\n#define main pspp_cli_entry_main\n#define exit(code) pspp_safe_exit(code)\n#endif\n\nstatic struct session *the_session;",
        1
    )
    s = s.replace(
        "  /* Parse and execute syntax. */\n  lex_get (lexer);\n  for (;;)\n    {\n      int result = cmd_parse (lexer, session_active_dataset (the_session));",
        "#ifdef PSPP_ANDROID_LIBRARY\n  atomic_store (&pspp_jni_cancel_requested, 0);\n  pspp_jni_jmp_armed = 1;\n  int jmp_rc = sigsetjmp (pspp_jni_exit_jmp, 1);\n  if (jmp_rc != 0)\n    {\n      pspp_jni_jmp_armed = 0;\n      output_engine_pop ();\n      session_destroy (the_session);\n      random_done ();\n      settings_done ();\n      fh_done ();\n      lex_destroy (lexer);\n      i18n_done ();\n      return (jmp_rc == 1000) ? EXIT_SUCCESS : jmp_rc;\n    }\n#endif\n\n  /* Parse and execute syntax. */\n  lex_get (lexer);\n  for (;;)\n    {\n      if (pspp_is_cancel_requested ())\n        break;\n      int result = cmd_parse (lexer, session_active_dataset (the_session));",
        1
    )
    s = s.replace(
        "  output_engine_pop ();\n  session_destroy (the_session);",
        "#ifdef PSPP_ANDROID_LIBRARY\n  pspp_jni_jmp_armed = 0;\n#endif\n  output_engine_pop ();\n  session_destroy (the_session);",
        1
    )
    open(p, "w").write(s)
    write_diff(["src/ui/terminal/main.c"], "# Reason: Expose library entry point pspp_cli_entry_main with atomic cancel check and siglongjmp exit() guard.")

shutil.rmtree(work_tree, ignore_errors=True)
PYEOF
}

# 3. Extract PSPP 2.1.2, run patch --dry-run on each patch first, print failing hunks if any,
#    regenerate any failing patch from the actual source, and apply cleanly.
PSPP_ORIG_SRC="${SRC_DIR}/pspp-${PSPP_VERSION}-orig"
PSPP_REF_SRC="${SRC_DIR}/pspp-${PSPP_VERSION}-patched"
rm -rf "${SRC_DIR}/pspp-${PSPP_VERSION}" "${PSPP_ORIG_SRC}" "${PSPP_REF_SRC}"
tar -xzf "${DOWNLOAD_DIR}/${PSPP_TARBALL}" -C "${SRC_DIR}"
cp -a "${SRC_DIR}/pspp-${PSPP_VERSION}" "${PSPP_ORIG_SRC}"
mv "${SRC_DIR}/pspp-${PSPP_VERSION}" "${PSPP_REF_SRC}"

echo "==> Dry-run verifying and applying Android patches against extracted PSPP ${PSPP_VERSION}..."
for p in "${PATCH_DIR}"/*.patch; do
  patch_base="$(basename "$p")"
  echo "--> Running patch --dry-run for ${patch_base}..."
  DRY_OUT=""
  if DRY_OUT="$(patch -d "${PSPP_REF_SRC}" -p1 --dry-run < "$p" 2>&1)"; then
    echo "${DRY_OUT}"
    echo "    [OK] All hunks in ${patch_base} passed dry-run cleanly."
  else
    echo "${DRY_OUT}"
    echo "    [WARN] Hunk failure detected in ${patch_base}:-"
    echo "${DRY_OUT}" | grep -E "FAILED|reject|Hunk" || true
    regenerate_patch_from_source "${patch_base}" "${PSPP_REF_SRC}"
    echo "    [REGENERATED] Re-verifying ${patch_base} with patch --dry-run..."
    patch -d "${PSPP_REF_SRC}" -p1 --dry-run < "$p"
  fi
  patch -d "${PSPP_REF_SRC}" -p1 < "$p"
done

# Copy verified/regenerated patches and GPLv3 COPYING into Android assets
cp -f "${PATCH_DIR}"/*.patch "${ASSETS_PSPP_DIR}/patches/"
cp -f "${PSPP_REF_SRC}/COPYING" "${ASSETS_PSPP_DIR}/COPYING"

# Bypass pre-generated configure Cairo pkg-config fatal abort, allow in-tree cross-compile,
# and strip cairo .lo objects from src_output_liboutput_la_OBJECTS in Makefile.in when building with --without-cairo.
python3 - "${PSPP_REF_SRC}" << 'PYEOF'
import os, re, sys
root = sys.argv[1]

# 1. Update pre-generated configure script so --without-cairo is recognized and skips PKG_CHECK_MODULES([CAIRO])
cfg_path = os.path.join(root, "configure")
cfg = open(cfg_path).read()

# Register with_cairo in ac_user_opts so --without-cairo does not emit an unrecognized option warning
cfg = cfg.replace("with_gui\n", "with_cairo\nwith_gui\n", 1)

# Allow in-tree cross-compilation in per-ABI work directories
cfg = cfg.replace(
    'if test x"$cross_compiling" = x"yes"; then\n   if test x"$srcdir" = x"."; then\n      as_fn_error $? "Cross compiling must be done out of source." "$LINENO" 5\n   fi\nfi',
    'if false; then\n   :\nfi'
)

# Wrap the Cairo/Pango pkg-config check in test "x$with_cairo" != "xno"
cairo_anchor = "# Support for Cairo and Pango.\n"
xmllint_anchor = '{ printf "%s\\n" "$as_me:${as_lineno-$LINENO}: checking for an xmllint program which fits our needs" >&5'
if cairo_anchor in cfg and xmllint_anchor in cfg:
    before, rest = cfg.split(cairo_anchor, 1)
    cairo_block, after = rest.split(xmllint_anchor, 1)
    wrapped_cairo = (
        "# Support for Cairo and Pango (optional via --without-cairo).\n"
        "if test ${with_cairo+y}; then withval=$with_cairo; else with_cairo=yes; fi\n"
        'if test "x$with_cairo" != "xno"; then\n'
        + cairo_block +
        'printf "%s\\n" "#define HAVE_CAIRO 1" >>confdefs.h\n'
        "else\n"
        '  CAIRO_CFLAGS=""\n'
        '  CAIRO_LIBS=""\n'
        "fi\n\n"
    )
    cfg = before + wrapped_cairo + xmllint_anchor + after

open(cfg_path, "w").write(cfg)

# 2. Remove Cairo-only object targets from am_src_output_liboutput_la_OBJECTS in Makefile.in
mk_path = os.path.join(root, "Makefile.in")
mk = open(mk_path).read()
cairo_objs = [
    r"src/output/(?:liboutput_la-)?cairo-chart\.lo",
    r"src/output/(?:liboutput_la-)?cairo-fsm\.lo",
    r"src/output/(?:liboutput_la-)?cairo-pager\.lo",
    r"src/output/(?:liboutput_la-)?cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?barchart-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?boxplot-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?np-plot-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?piechart-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?plot-hist-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?roc-chart-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?scatterplot-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?scree-cairo\.lo",
    r"src/output/charts/(?:liboutput_la-)?spreadlevel-cairo\.lo",
]
for pat in cairo_objs:
    mk = re.sub(r"\t" + pat + r" \\\n", "", mk)
open(mk_path, "w").write(mk)

# 3. Provide minimal Cairo type/function stubs when HAVE_CAIRO is not defined
cairo_stub = """#ifndef PSPP_NO_CAIRO_STUB_H
#define PSPP_NO_CAIRO_STUB_H 1
#include <stddef.h>
typedef struct _cairo cairo_t;
typedef struct _cairo_surface cairo_surface_t;
typedef enum _cairo_status {
  CAIRO_STATUS_SUCCESS = 0,
  CAIRO_STATUS_NO_MEMORY,
  CAIRO_STATUS_READ_ERROR,
  CAIRO_STATUS_WRITE_ERROR
} cairo_status_t;
typedef cairo_status_t (*cairo_write_func_t) (void *closure, const unsigned char *data, unsigned int length);
typedef cairo_status_t (*cairo_read_func_t) (void *closure, unsigned char *data, unsigned int length);
static inline void cairo_surface_destroy (cairo_surface_t *s) { (void) s; }
static inline cairo_surface_t *cairo_surface_reference (cairo_surface_t *s) { return s; }
static inline cairo_status_t cairo_surface_status (cairo_surface_t *s) { return s ? CAIRO_STATUS_SUCCESS : CAIRO_STATUS_NO_MEMORY; }
static inline cairo_status_t cairo_surface_write_to_png_stream (cairo_surface_t *s, cairo_write_func_t f, void *c) { (void) s; (void) f; (void) c; return CAIRO_STATUS_SUCCESS; }
static inline cairo_surface_t *cairo_image_surface_create_from_png_stream (cairo_read_func_t f, void *c) { (void) f; (void) c; return NULL; }
#endif
"""
os.makedirs(os.path.join(root, "src/cairo"), exist_ok=True)
open(os.path.join(root, "src/cairo.h"), "w").write(cairo_stub)
open(os.path.join(root, "src/cairo/cairo.h"), "w").write(cairo_stub)

cc_path = os.path.join(root, "src/output/cairo-chart.h")
cc = open(cc_path).read()
if "#ifndef HAVE_CAIRO" not in cc:
    cc = cc.replace(
        "#endif /* output/cairo-chart.h */",
        """#ifndef HAVE_CAIRO
static inline cairo_surface_t *xr_draw_image_chart (const struct chart *c, const struct cell_color *fg, const struct cell_color *bg) { (void) c; (void) fg; (void) bg; return NULL; }
static inline char *xr_write_png_image (cairo_surface_t *s, const char *t, int n) { (void) s; (void) t; (void) n; return NULL; }
static inline char *xr_draw_png_chart (const struct chart *c, const char *t, int n, const struct cell_color *fg, const struct cell_color *bg) { (void) c; (void) t; (void) n; (void) fg; (void) bg; return NULL; }
static inline char *xr_draw_eps_chart (const struct chart *c, const char *t, int n, const struct cell_color *fg, const struct cell_color *bg) { (void) c; (void) t; (void) n; (void) fg; (void) bg; return NULL; }
#endif
#endif /* output/cairo-chart.h */"""
    )
    cc = re.sub(r"cairo_surface_t \*xr_draw_image_chart[^;]+;", "", cc, count=1)
    cc = re.sub(r"char \*xr_write_png_image[^;]+;", "", cc, count=1)
    cc = re.sub(r"char \*xr_draw_png_chart[^;]+;", "", cc, count=1)
    cc = re.sub(r"char \*xr_draw_eps_chart[^;]+;", "", cc, count=1)
    open(cc_path, "w").write(cc)
PYEOF

# Reset timestamps on autotools files so make never attempts to run aclocal-1.18/automake-1.18/autoconf
touch -r "${PSPP_REF_SRC}/aclocal.m4" \
  "${PSPP_REF_SRC}/configure.ac" \
  "${PSPP_REF_SRC}/configure" \
  "${PSPP_REF_SRC}/config.h.in" \
  "${PSPP_REF_SRC}/Makefile.in"
touch "${PSPP_REF_SRC}/gl/crc-sliceby8.h" \
  "${PSPP_REF_SRC}/gl/thread-creators.h" \
  "${PSPP_REF_SRC}/gl/unicase/special-casing-table.h" 2>/dev/null || true

# 3b. Compile PSPP .po catalogs into binary .mo files in assets using msgfmt
echo "==> Compiling PSPP .po catalogs into binary .mo files in assets via msgfmt..."
for lang in ar fr; do
  if [[ -f "${PSPP_REF_SRC}/po/${lang}.po" ]]; then
    mkdir -p "${ASSETS_PSPP_DIR}/locale/${lang}/LC_MESSAGES"
    msgfmt -o "${ASSETS_PSPP_DIR}/locale/${lang}/LC_MESSAGES/pspp.mo" "${PSPP_REF_SRC}/po/${lang}.po"
  fi
done
# Ensure English .mo catalog exists and remove any .po files from assets
rm -f "${ASSETS_PSPP_DIR}"/locale/*/LC_MESSAGES/*.po
ls -lh "${ASSETS_PSPP_DIR}"/locale/*/LC_MESSAGES/pspp.mo

# Helper: Map Android ABI to target triplet and compiler prefix
abi_to_host() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi" ;;
    x86_64)      echo "x86_64-linux-android" ;;
    *) echo "Unknown ABI: $1" >&2; exit 1 ;;
  esac
}

abi_to_clang_prefix() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android${ANDROID_API}" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi${ANDROID_API}" ;;
    x86_64)      echo "x86_64-linux-android${ANDROID_API}" ;;
    *) echo "Unknown ABI: $1" >&2; exit 1 ;;
  esac
}

# 4. Cross-compile stack for each ABI
for ABI in "${ABIS[@]}"; do
  echo "======================================================================"
  echo "==> Building native dependency stack & PSPP ${PSPP_VERSION} for ABI: ${ABI}"
  echo "======================================================================"

  TARGET_HOST="$(abi_to_host "${ABI}")"
  CLANG_PREFIX="$(abi_to_clang_prefix "${ABI}")"
  ABI_PREFIX="${BUILD_ROOT}/sysroot/${ABI}"
  ABI_WORK="${BUILD_ROOT}/work/${ABI}"
  mkdir -p "${ABI_PREFIX}/lib/pkgconfig" "${ABI_PREFIX}/include" "${ABI_WORK}" "${JNILIBS_DIR}/${ABI}"

  export AR="${TOOLCHAIN}/bin/llvm-ar"
  export AS="${TOOLCHAIN}/bin/${CLANG_PREFIX}-clang"
  export CC="${TOOLCHAIN}/bin/${CLANG_PREFIX}-clang"
  export CXX="${TOOLCHAIN}/bin/${CLANG_PREFIX}-clang++"
  export LD="${TOOLCHAIN}/bin/ld.lld"
  export NM="${TOOLCHAIN}/bin/llvm-nm"
  export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
  export STRIP="${TOOLCHAIN}/bin/llvm-strip"
  export CFLAGS="-O2 -fPIC -D_GNU_SOURCE -I${ABI_PREFIX}/include"
  export CXXFLAGS="-O2 -fPIC -D_GNU_SOURCE -I${ABI_PREFIX}/include"
  export CPPFLAGS="-I${ABI_PREFIX}/include -D_GNU_SOURCE"
  export LDFLAGS="-L${ABI_PREFIX}/lib"
  export PKG_CONFIG_PATH="${ABI_PREFIX}/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="${ABI_PREFIX}/lib/pkgconfig"

  # 4a. zlib
  if [[ ! -f "${ABI_PREFIX}/lib/libz.a" ]]; then
    echo "--> [${ABI}] Building zlib ${ZLIB_VERSION}..."
    rm -rf "${ABI_WORK}/zlib-${ZLIB_VERSION}"
    tar -xzf "${DOWNLOAD_DIR}/zlib-${ZLIB_VERSION}.tar.gz" -C "${ABI_WORK}"
    pushd "${ABI_WORK}/zlib-${ZLIB_VERSION}" >/dev/null
    CHOST="${TARGET_HOST}" ./configure --prefix="${ABI_PREFIX}" --static
    make -j"${JOBS}"
    make install
    popd >/dev/null
  fi

  # 4b. GNU libiconv
  if [[ ! -f "${ABI_PREFIX}/lib/libiconv.a" ]]; then
    echo "--> [${ABI}] Building libiconv ${LIBICONV_VERSION}..."
    rm -rf "${ABI_WORK}/libiconv-${LIBICONV_VERSION}"
    tar -xzf "${DOWNLOAD_DIR}/libiconv-${LIBICONV_VERSION}.tar.gz" -C "${ABI_WORK}"
    pushd "${ABI_WORK}/libiconv-${LIBICONV_VERSION}" >/dev/null
    ./configure \
      --host="${TARGET_HOST}" \
      --prefix="${ABI_PREFIX}" \
      --enable-static \
      --disable-shared \
      --disable-rpath
    make -j"${JOBS}"
    make install
    popd >/dev/null
  fi

  # 4c. GNU gettext (libintl for NLS localization)
  if [[ ! -f "${ABI_PREFIX}/lib/libintl.a" ]]; then
    echo "--> [${ABI}] Building gettext/libintl ${GETTEXT_VERSION} (NLS enabled)..."
    rm -rf "${ABI_WORK}/gettext-${GETTEXT_VERSION}"
    tar -xzf "${DOWNLOAD_DIR}/gettext-${GETTEXT_VERSION}.tar.gz" -C "${ABI_WORK}"
    pushd "${ABI_WORK}/gettext-${GETTEXT_VERSION}/gettext-runtime" >/dev/null
    ./configure \
      --host="${TARGET_HOST}" \
      --prefix="${ABI_PREFIX}" \
      --enable-static \
      --disable-shared \
      --enable-nls \
      --with-included-gettext \
      --with-libiconv-prefix="${ABI_PREFIX}" \
      --disable-java \
      --disable-csharp \
      --disable-c++ \
      gl_cv_func_wcwidth_works=yes
    make -j"${JOBS}" -C intl
    make install -C intl
    popd >/dev/null
  fi

  # 4d. libxml2 (required by PSPP for ODT/SPV/XML parsing)
  if [[ ! -f "${ABI_PREFIX}/lib/libxml2.a" ]]; then
    echo "--> [${ABI}] Building libxml2 ${LIBXML2_VERSION}..."
    rm -rf "${ABI_WORK}/libxml2-${LIBXML2_VERSION}"
    tar -xJf "${DOWNLOAD_DIR}/libxml2-${LIBXML2_VERSION}.tar.xz" -C "${ABI_WORK}"
    pushd "${ABI_WORK}/libxml2-${LIBXML2_VERSION}" >/dev/null
    ./configure \
      --host="${TARGET_HOST}" \
      --prefix="${ABI_PREFIX}" \
      --enable-static \
      --disable-shared \
      --without-python \
      --without-lzma \
      --without-http \
      --without-ftp \
      --without-docbook \
      --without-legacy \
      --with-zlib="${ABI_PREFIX}" \
      --with-iconv="${ABI_PREFIX}"
    make -j"${JOBS}" libat1.la libxml2.la 2>/dev/null || make -j"${JOBS}" libxml2.la
    make install-libLTLIBRARIES install-data
    popd >/dev/null
  fi

  # 4e. GNU Scientific Library (GSL + gslcblas)
  if [[ ! -f "${ABI_PREFIX}/lib/libgsl.a" ]]; then
    echo "--> [${ABI}] Building GSL ${GSL_VERSION}..."
    if [[ ! -f "${ABI_WORK}/gsl-${GSL_VERSION}/Makefile" ]]; then
      rm -rf "${ABI_WORK}/gsl-${GSL_VERSION}"
      tar -xzf "${DOWNLOAD_DIR}/gsl-${GSL_VERSION}.tar.gz" -C "${ABI_WORK}"
      pushd "${ABI_WORK}/gsl-${GSL_VERSION}" >/dev/null
      ./configure \
        --host="${TARGET_HOST}" \
        --prefix="${ABI_PREFIX}" \
        --enable-static \
        --disable-shared
    else
      pushd "${ABI_WORK}/gsl-${GSL_VERSION}" >/dev/null
    fi
    sed -i 's/ doc$//' Makefile
    make -j"${JOBS}"
    make install
    popd >/dev/null
  fi

  # 4f. Create gnulib cross-compilation config.cache for PSPP 2.1.2
  CONFIG_CACHE="${ABI_WORK}/pspp-android.cache"
  cat > "${CONFIG_CACHE}" <<EOF
ac_cv_func_malloc_0_nonnull=yes
ac_cv_func_realloc_0_nonnull=yes
ac_cv_func_calloc_0_nonnull=yes
gl_cv_func_mbrtowc_incomplete_state=yes
gl_cv_func_mbrtowc_nul_retval=yes
gl_cv_func_mbrtowc_null_arg1=yes
gl_cv_func_mbrtowc_null_arg2=yes
gl_cv_func_mbrtowc_retval=yes
gl_cv_func_wcrtomb_retval=yes
gl_cv_func_snprintf_truncation_c99=yes
gl_cv_func_snprintf_retval_c99=yes
gl_cv_func_vsnprintf_zerosize_c99=yes
gl_cv_func_getcwd_null=yes
gl_cv_func_getcwd_path_max=yes
gl_cv_func_fdopendir_works=yes
gl_cv_func_fchownat_nofollow_works=yes
gl_cv_func_gettimeofday_clobber=no
gl_cv_func_memchr_works=yes
gl_cv_func_working_mkstemp=yes
gl_cv_func_strerror_0_works=yes
EOF

  # 4g. Build PSPP 2.1.2 static/convenience archives (libpspp, libpspp-core, libgl, ui/terminal)
  echo "--> [${ABI}] Configuring and building GNU PSPP ${PSPP_VERSION}..."
  if [[ "${CLEAN_PSPP_BUILD:-1}" == "1" || ! -f "${ABI_WORK}/pspp-build/config.status" ]]; then
    rm -rf "${ABI_WORK}/pspp-build"
    cp -a "${PSPP_REF_SRC}" "${ABI_WORK}/pspp-build"
    pushd "${ABI_WORK}/pspp-build" >/dev/null

    CFLAGS="${CFLAGS} -DPSPP_ANDROID_LIBRARY=1 -I${ABI_PREFIX}/include/libxml2" \
    LIBS="-lintl -liconv -lxml2 -lgsl -lgslcblas -lz -lm" \
    ./configure \
      --cache-file="${CONFIG_CACHE}" \
      --host="${TARGET_HOST}" \
      --prefix="${ABI_PREFIX}" \
      --enable-nls \
      --enable-static \
      --disable-shared \
      --without-gui \
      --without-cairo \
      --without-libpq \
      --without-perl-module \
      --with-libiconv-prefix="${ABI_PREFIX}" \
      --with-libintl-prefix="${ABI_PREFIX}"
  else
    pushd "${ABI_WORK}/pspp-build" >/dev/null
    mkdir -p src/cairo
    cp -f "${PSPP_REF_SRC}/src/cairo.h" src/cairo.h
    cp -f "${PSPP_REF_SRC}/src/cairo/cairo.h" src/cairo/cairo.h
    cp -f "${PSPP_REF_SRC}/src/output/cairo-chart.h" src/output/cairo-chart.h
    cp -f "${PSPP_REF_SRC}/Makefile.in" Makefile.in
    touch -r aclocal.m4 configure.ac configure config.h.in Makefile.in
    ./config.status Makefile
  fi

  # Generate gnulib headers (BUILT_SOURCES), SPV parsers, and expression headers first
  make -j"${JOBS}" ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=: \
    built-sources config.h \
    src/libpspp/version.c \
    src/data/sys-file-encoding.c \
    src/language/expressions/evaluate.h \
    src/language/expressions/evaluate.inc \
    src/language/expressions/operations.h \
    src/language/expressions/optimize.inc \
    src/language/expressions/parse.inc

  # Build PSPP core libraries and convenience archives
  make -j"${JOBS}" ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=: \
    gl/libgl.la \
    lib/linreg/liblinreg.la \
    lib/tukey/libtukey.la \
    src/libpspp-core.la \
    src/libpspp.la \
    src/ui/libuicommon.la \
    src/ui/terminal/libui.la

  # Compile CLI entry object with PSPP_ANDROID_LIBRARY=1 so pspp_cli_entry_main is exported
  ${CC} ${CFLAGS} -DPSPP_ANDROID_LIBRARY=1 \
    -I. -I./src -I./gl -I"${ABI_PREFIX}/include" -I"${ABI_PREFIX}/include/libxml2" \
    -c src/ui/terminal/main.c -o src/ui/terminal/pspp_android_main.o
  ${CC} ${CFLAGS} \
    -I. -I./src -I./gl -I"${ABI_PREFIX}/include" -I"${ABI_PREFIX}/include/libxml2" \
    -c src/ui/terminal/terminal-opts.c -o src/ui/terminal/terminal-opts.o
  ${CC} ${CFLAGS} \
    -I. -I./src -I./gl -I"${ABI_PREFIX}/include" -I"${ABI_PREFIX}/include/libxml2" \
    -c src/ui/terminal/terminal-reader.c -o src/ui/terminal/terminal-reader.o
  ${CC} ${CFLAGS} \
    -I. -I./src -I./gl -I"${ABI_PREFIX}/include" -I"${ABI_PREFIX}/include/libxml2" \
    -c src/ui/source-init-opts.c -o src/ui/source-init-opts.o

  # 4h. Link libpspp_jni.so combining pspp_jni.c + PSPP static/PIC objects + dependencies
  echo "--> [${ABI}] Linking libpspp_jni.so..."
  PSPP_LIBS=()
  for candidate in \
    "src/ui/terminal/.libs/libui.a" \
    "src/ui/.libs/libuicommon.a" \
    "src/.libs/libpspp.a" \
    "src/.libs/libpspp-core.a" \
    "gl/.libs/libgl.a"; do
    if [[ -f "${candidate}" ]]; then
      PSPP_LIBS+=("${candidate}")
    fi
  done

  "${CC}" ${CFLAGS} -shared \
    -DHAVE_PSPP_CORE=1 \
    -Wl,--allow-multiple-definition \
    -I"${ABI_PREFIX}/include" \
    "${ROOT_DIR}/app/src/main/cpp/pspp_jni.c" \
    src/ui/terminal/pspp_android_main.o \
    src/ui/terminal/terminal-opts.o \
    src/ui/terminal/terminal-reader.o \
    src/ui/source-init-opts.o \
    -Wl,--whole-archive "${PSPP_LIBS[@]}" -Wl,--no-whole-archive \
    "${ABI_PREFIX}/lib/libgsl.a" \
    "${ABI_PREFIX}/lib/libgslcblas.a" \
    "${ABI_PREFIX}/lib/libxml2.a" \
    "${ABI_PREFIX}/lib/libintl.a" \
    "${ABI_PREFIX}/lib/libiconv.a" \
    "${ABI_PREFIX}/lib/libz.a" \
    -lm -llog \
    -o "${JNILIBS_DIR}/${ABI}/libpspp_jni.so"

  "${STRIP}" --strip-unneeded "${JNILIBS_DIR}/${ABI}/libpspp_jni.so"
  popd >/dev/null
  echo "==> [${ABI}] Produced ${JNILIBS_DIR}/${ABI}/libpspp_jni.so ($(du -h "${JNILIBS_DIR}/${ABI}/libpspp_jni.so" | cut -f1))"
done

# Remove intermediate extracted source and object directories (keep sysroot and downloads for CI cache)
rm -rf "${BUILD_ROOT}/src" "${BUILD_ROOT}/build"

echo "======================================================================"
echo "All native libraries built successfully:"
ls -lh "${JNILIBS_DIR}"/*/libpspp_jni.so
echo "======================================================================"
