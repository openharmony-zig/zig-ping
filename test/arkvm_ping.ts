declare function requireNapiPreview(name: string, isApp: boolean): ESObject;
declare function print(message: string): void;
declare function setInterval(callback: () => void, delay: number): number;
declare function clearInterval(id: number): void;

type NativeAddon = ESObject;

const RESULT_PREFIX = "__ZIG_PING_ARKVM_RESULT__";
const KEEP_ALIVE_INTERVAL_MS = 10;
const SUITE_TIMEOUT_MS = 30000;

function fail(message: string): never {
  print(`${RESULT_PREFIX} status=fail message=${message}`);
  throw new Error(message);
}

function assert(condition: boolean, message: string) {
  if (!condition) {
    fail(message);
  }
}

async function assertRejects(promise: Promise<ESObject>, expectedMessage: string, message: string) {
  let rejected = false;
  try {
    await promise;
  } catch (err) {
    rejected = true;
    const actual = String(err && (err.message || err));
    assert(actual.indexOf(expectedMessage) >= 0, `${message}: ${actual}`);
  }
  assert(rejected, `${message}: expected rejection`);
}

function assertIPv4(value: string, message: string) {
  assert(/^\d{1,3}(\.\d{1,3}){3}$/.test(value), `${message}: ${value}`);
}

function assertIPv6(value: string, message: string) {
  assert(value.indexOf(":") >= 0, `${message}: ${value}`);
}

async function assertPingResult(
  native: NativeAddon,
  host: string,
  ipVersion: string,
  checkIP: (value: string, message: string) => void,
) {
  const results = await native.ping(host, {
    count: 1,
    interval_ms: 1,
    timeout_ms: 1000,
    ip_version: ipVersion,
  });

  assert(Array.isArray(results), `${host} ${ipVersion} result should be an array`);
  assert(results.length === 1, `${host} ${ipVersion} result should contain one item`);

  const first = results[0];
  assert(typeof first.sequence === "number", `${host} ${ipVersion} sequence should be a number`);
  assert(typeof first.rtt_ms === "number", `${host} ${ipVersion} rtt_ms should be a number`);
  assert(typeof first.success === "boolean", `${host} ${ipVersion} success should be a boolean`);
  assert(first.success === true, `${host} ${ipVersion} ping should succeed`);
  assert(typeof first.ip_addr === "string", `${host} ${ipVersion} ip_addr should be a string`);
  checkIP(first.ip_addr, `${host} ${ipVersion} ip_addr`);
}

function installTimerRuntime() {
  const etsInterop = requireNapiPreview("ets_interop_js_napi", true) as ESObject;
  const created = etsInterop.createRuntime({
    "panda-files": "./hello.abc",
    "boot-panda-files": "./etsstdlib.abc:./hello.abc",
    "xgc-trigger-type": "never",
  });
  assert(!!created, "failed to initialize ArkVM timer runtime");
}

async function run(native: NativeAddon) {
  assert(typeof native.ping === "function", "ping export should be a function");

  await assertRejects(
    native.ping("zig-ping.invalid", { count: 1, timeout_ms: 10, ip_version: "ipv4" }),
    "Failed to get IP address",
    "invalid host should reject",
  );

  await assertPingResult(native, "127.0.0.1", "ipv4", assertIPv4);
  await assertPingResult(native, "127.0.0.1.sslip.io", "ipv4", assertIPv4);
  await assertPingResult(
    native,
    "0000-0000-0000-0000-0000-0000-0000-0001.sslip.io",
    "ipv6",
    assertIPv6,
  );
}

installTimerRuntime();

let finished = false;
let elapsed = 0;
const keepAlive = setInterval(() => {
  if (finished) {
    clearInterval(keepAlive);
    return;
  }
  elapsed += KEEP_ALIVE_INTERVAL_MS;
  if (elapsed >= SUITE_TIMEOUT_MS) {
    finished = true;
    clearInterval(keepAlive);
    fail(`suite timed out after ${SUITE_TIMEOUT_MS}ms`);
  }
}, KEEP_ALIVE_INTERVAL_MS);

Promise.resolve()
  .then(() => run(requireNapiPreview("zig_ping", true) as NativeAddon))
  .then(
    () => {
      if (finished) {
        return;
      }
      finished = true;
      clearInterval(keepAlive);
      print(`${RESULT_PREFIX} status=ok`);
    },
    (err) => {
      if (finished) {
        return;
      }
      finished = true;
      clearInterval(keepAlive);
      const message = String(err && (err.message || err));
      fail(message);
    },
  );
