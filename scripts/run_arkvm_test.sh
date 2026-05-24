#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

: "${ARK_HOST_TOOLS_DIR:?ARK_HOST_TOOLS_DIR is required}"

ARK_ES2ABC="${ARK_HOST_TOOLS_DIR}/es2abc"
ARK_JS_NAPI_CLI="${ARK_HOST_TOOLS_DIR}/ark_js_napi_cli"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-90}"
RESULT_GRACE_SEC="${RESULT_GRACE_SEC:-2}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
WORK_ROOT="${ARKVM_WORK_ROOT:-${ROOT_DIR}/.tmp_arkvm_runner}"
WORKSPACE="${WORK_ROOT}/ping"
ABC="${WORKSPACE}/suite.abc"
FILES_INFO="${WORKSPACE}/filesInfo.txt"
LOG_FILE="${WORKSPACE}/arkvm.log"
RESULT_PREFIX="__ZIG_PING_ARKVM_RESULT__"

[[ -x "${ARK_ES2ABC}" ]] || { echo "Missing binary: ${ARK_ES2ABC}" >&2; exit 1; }
[[ -x "${ARK_JS_NAPI_CLI}" ]] || { echo "Missing binary: ${ARK_JS_NAPI_CLI}" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libace_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libace_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" ]] || { echo "Missing ArkTS stdlib: ${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/hello.abc" ]] || { echo "Missing ArkVM fixture abc: ${ARK_HOST_TOOLS_DIR}/hello.abc" >&2; exit 1; }

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}/module"

if [[ "${ARKVM_SKIP_BUILD:-0}" != "1" ]]; then
  (cd "${ROOT_DIR}" && zig build -Darkvm-test=true -Doptimize=ReleaseSafe)
fi

cp "${ROOT_DIR}/zig-out/arkvm-host/libzig_ping.so" "${WORKSPACE}/module/"
ln -sf "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" "${WORKSPACE}/module/libets_interop_js_napi.so"
cp "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" "${WORKSPACE}/"
cp "${ARK_HOST_TOOLS_DIR}/hello.abc" "${WORKSPACE}/"

TEST_SOURCE="${ROOT_DIR}/test/arkvm_ping.ts"
TEST_REL="${TEST_SOURCE#${ROOT_DIR}/}"
TEST_RECORD="${TEST_REL%.*}"
printf '%s;%s;esm;%s;%s;false\n' "${TEST_SOURCE}" "${TEST_RECORD}" "${TEST_REL}" "${TEST_RECORD}" > "${FILES_INFO}"
"${ARK_ES2ABC}" --merge-abc --extension=ts --module --output "${ABC}" "@${FILES_INFO}"

: > "${LOG_FILE}"
(
  cd "${WORKSPACE}"
  export LD_LIBRARY_PATH="${WORKSPACE}:${WORKSPACE}/module:${ARK_HOST_TOOLS_DIR}:${LD_LIBRARY_PATH:-}"
  "${ARK_JS_NAPI_CLI}" --entry-point "${TEST_RECORD}" "${ABC}"
) >"${LOG_FILE}" 2>&1 &

pid=$!
deadline=$((SECONDS + TEST_TIMEOUT_SEC))
result_deadline=0
while kill -0 "${pid}" 2>/dev/null; do
  if (( result_deadline == 0 )) && grep -q "^${RESULT_PREFIX}" "${LOG_FILE}" 2>/dev/null; then
    result_deadline=$((SECONDS + RESULT_GRACE_SEC))
  fi
  if (( result_deadline != 0 && SECONDS >= result_deadline )); then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" >/dev/null 2>&1 || true
    break
  fi
  if (( SECONDS >= deadline )); then
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" >/dev/null 2>&1 || true
    echo "ArkVM test timed out after ${TEST_TIMEOUT_SEC}s" >&2
    cat "${LOG_FILE}" >&2
    exit 124
  fi
  sleep 0.2
done

cat "${LOG_FILE}"
if grep -Eq 'error\(DebugAllocator\)|Segmentation fault|SIGSEGV|panic:|Cannot execute panda file|load native module failed' "${LOG_FILE}"; then
  echo "ArkVM test emitted a fatal runtime diagnostic" >&2
  exit 1
fi
grep -q "^${RESULT_PREFIX} status=ok" "${LOG_FILE}"

[[ "${KEEP_WORKDIR}" == "1" ]] || rm -rf "${WORKSPACE}"
