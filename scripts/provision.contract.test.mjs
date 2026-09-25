// Contract tests for the operator credential handling in provision.sh and
// provision.ps1. Each script runs against a local stand-in for the platform's
// setup, authorize and login routes, and the test checks which password
// actually reached the platform for every supported source: --password-stdin,
// EDK_OPERATOR_PASSWORD, a private environment file and the terminal prompt.
// The prompt runs under a real pseudo-terminal through util-linux `script`; it
// is skipped where `script` is not installed (Windows).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const shellScript = path.join(scriptsDir, "provision.sh").replace(/\\/g, "/");
const psScript = path.join(scriptsDir, "provision.ps1");
const isWindows = process.platform === "win32";
const OPERATOR = "operator@acme.example";

function findBash() {
  if (process.env.EDK_TEST_BASH) return process.env.EDK_TEST_BASH;
  if (isWindows) {
    // Avoid the WSL launcher in System32: the scripts target Git Bash on Windows.
    const gitBash = "C:/Program Files/Git/bin/bash.exe";
    return fs.existsSync(gitBash) ? gitBash : null;
  }
  return "bash";
}

function hasCommand(command, args = ["--version"]) {
  if (!command) return false;
  const result = spawnSync(command, args, { stdio: "ignore" });
  return !result.error && result.status === 0;
}

const bash = findBash();
const powershells = [
  ...(hasCommand("pwsh", ["-NoProfile", "-Command", "exit 0"]) ? ["pwsh"] : []),
  ...(isWindows && hasCommand("powershell.exe", ["-NoProfile", "-Command", "exit 0"]) ? ["powershell.exe"] : []),
];
const hasScript = !isWindows && hasCommand("script", ["--version"]);

// --- Stand-in platform --------------------------------------------------------
async function startPlatform({ setupOpen }) {
  const requests = [];
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const raw = Buffer.concat(chunks);
    const url = new URL(request.url, "http://stub");
    const contentType = request.headers["content-type"] || "";
    const record = { method: request.method, path: url.pathname };
    if (contentType.startsWith("application/json")) record.json = JSON.parse(raw.toString("utf8"));
    if (contentType.startsWith("application/x-www-form-urlencoded")) {
      record.form = Object.fromEntries(new URLSearchParams(raw.toString("utf8")));
    }
    requests.push(record);

    const base = `http://127.0.0.1:${server.address().port}`;
    const json = (status, body) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    };
    const redirect = (location) => {
      response.writeHead(302, { location });
      response.end();
    };

    if (url.pathname === "/api/platform/setup/v1/status") return json(setupOpen ? 200 : 404, {});
    if (url.pathname.startsWith("/api/platform/setup/v1/license/import")) return json(200, {});
    if (url.pathname === "/api/platform/setup/v1/bootstrap") {
      return json(200, { activation: { manualActivationLink: `${base}/account-action#activation-token` } });
    }
    if (url.pathname === "/api/account-actions/v1/complete") return json(200, {});
    if (url.pathname === "/authorize") return redirect(`${base}/login?session_id=sid-1&return_url=%2Fresume`);
    if (url.pathname === "/login" && request.method === "GET") {
      response.writeHead(200, { "content-type": "text/html" });
      return response.end('<form><input type="hidden" name="tab_id" value="tab-1">' +
        '<input type="hidden" name="session_code" value="code-1"></form>');
    }
    // The stand-in rejects every login; the tests only need the submitted form.
    if (url.pathname === "/login" && request.method === "POST") {
      return redirect(`${base}/admin-console/callback?error=invalid_credentials`);
    }
    if (url.pathname === "/admin-console/callback") return json(200, {});
    return json(404, { error: "unexpected route" });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    requests,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function writeEnvironment(dir, platformUrl, extra = {}) {
  const values = {
    baseDomain: "example.test",
    tenantSlug: "acme",
    tenantName: "Acme",
    platformUrl,
    ...extra,
  };
  const file = path.join(dir, "environment.json");
  fs.writeFileSync(file, JSON.stringify({
    name: "provision-contract",
    values: Object.entries(values).map(([key, value]) => ({ key, value, enabled: true })),
  }));
  return file;
}

function scriptEnv(extra) {
  const env = { ...process.env, ...extra };
  for (const key of ["EDK_OPERATOR_EMAIL", "EDK_OPERATOR_PASSWORD", "EDK_LICENSE_BUNDLE_ZIP_PATH"]) {
    if (!(key in extra)) delete env[key];
  }
  return env;
}

// Runs one script variant. `shell` is "bash", "pwsh" or "powershell.exe".
function run(shell, { envFile, email, passwordStdin, stdin = "", licenseBundle, skipSetup, env = {} }) {
  let command;
  let args;
  if (shell === "bash") {
    command = bash;
    const slashes = (value) => value.replace(/\\/g, "/");
    args = [shellScript, "--env-file", slashes(envFile)];
    if (email) args.push("--operator-email", email);
    if (passwordStdin) args.push("--password-stdin");
    if (licenseBundle) args.push("--license-bundle", slashes(licenseBundle));
    if (skipSetup) args.push("--skip-setup");
  } else {
    command = shell;
    args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", psScript, "-EnvFile", envFile];
    if (email) args.push("-OperatorEmail", email);
    if (passwordStdin) args.push("-PasswordStdin");
    if (licenseBundle) args.push("-LicenseBundle", licenseBundle);
    if (skipSetup) args.push("-SkipSetup");
  }
  return new Promise((resolve) => {
    const child = spawn(command, args, { env: scriptEnv(env), stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    child.stdin.end(stdin);
    const timer = setTimeout(() => child.kill(), 120_000);
    child.on("close", (code) => {
      clearTimeout(timer);
      if (process.env.PROVISION_TEST_DEBUG) console.error(`--- ${shell} exit ${code}\n${output}`);
      resolve({ code, output });
    });
  });
}

// Runs a script under a pseudo-terminal with `script`, typing `typed` at the prompt.
function runInTerminal(shell, { envFile, email }) {
  const quote = (value) => `'${String(value).replace(/'/g, "'\\''")}'`;
  const inner = shell === "bash"
    ? `bash ${quote(shellScript)} --env-file ${quote(envFile)} --operator-email ${quote(email)} --skip-setup`
    : `${shell} -NoProfile -File ${quote(psScript)} -EnvFile ${quote(envFile)} -OperatorEmail ${quote(email)} -SkipSetup`;
  return new Promise((resolve) => {
    const child = spawn("script", ["-qefc", inner, "/dev/null"], { env: scriptEnv({}), stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
      // Type the password only once the prompt is on screen.
      if (/Password for/.test(output) && !child.typed) {
        child.typed = true;
        child.stdin.write("typed-at-the-prompt\r");
      }
    });
    child.stderr.on("data", (chunk) => { output += chunk; });
    const timer = setTimeout(() => child.kill(), 120_000);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, output });
    });
  });
}

const activationPassword = (requests) => requests.find((r) => r.path === "/api/account-actions/v1/complete")?.json?.password;
const loginPassword = (requests) => requests.find((r) => r.path === "/login" && r.method === "POST")?.form?.password;

const shells = [...(bash ? ["bash"] : []), ...powershells];

for (const shell of shells) {
  test(`${shell}: password from --password-stdin wins over EDK_OPERATOR_PASSWORD and reaches activation intact`, async () => {
    const platform = await startPlatform({ setupOpen: true });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const bundle = path.join(dir, "license-bundle.zip");
      fs.writeFileSync(bundle, "PK\u0003\u0004bundle");
      const result = await run(shell, {
        envFile: writeEnvironment(dir, platform.url),
        email: OPERATOR,
        passwordStdin: true,
        stdin: "-from-stdin Passw0rd\r\n",
        licenseBundle: bundle,
        env: { EDK_OPERATOR_PASSWORD: "from-environment" },
      });
      assert.match(result.output, /Operator activated/);
      assert.equal(activationPassword(platform.requests), "-from-stdin Passw0rd");
      assert.equal(loginPassword(platform.requests), "-from-stdin Passw0rd");
      const bootstrap = platform.requests.find((r) => r.path === "/api/platform/setup/v1/bootstrap");
      assert.equal(bootstrap.json.adminEmail, OPERATOR);
      assert.match(result.output, /invalid credentials/);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test(`${shell}: password and email from environment variables`, async () => {
    const platform = await startPlatform({ setupOpen: false });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const result = await run(shell, {
        envFile: writeEnvironment(dir, platform.url),
        skipSetup: true,
        env: { EDK_OPERATOR_EMAIL: OPERATOR, EDK_OPERATOR_PASSWORD: "-env Passw0rd&x=1" },
      });
      assert.equal(loginPassword(platform.requests), "-env Passw0rd&x=1");
      assert.equal(platform.requests.find((r) => r.path === "/login" && r.method === "POST").form.username, OPERATOR);
      assert.match(result.output, /invalid credentials/);
      assert.equal(result.code, 1);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test(`${shell}: password from a private environment file`, async () => {
    const platform = await startPlatform({ setupOpen: false });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const result = await run(shell, {
        envFile: writeEnvironment(dir, platform.url, { operatorEmail: OPERATOR, operatorPassword: "from-private-file" }),
        skipSetup: true,
      });
      assert.equal(loginPassword(platform.requests), "from-private-file");
      assert.match(result.output, /invalid credentials/);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test(`${shell}: without a password and without a terminal it fails before any sign-in`, async () => {
    const platform = await startPlatform({ setupOpen: false });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const result = await run(shell, { envFile: writeEnvironment(dir, platform.url), email: OPERATOR, skipSetup: true });
      assert.equal(result.code, 1);
      assert.match(result.output, /operator password is not set/);
      assert.match(result.output, shell === "bash" ? /--password-stdin/ : /-PasswordStdin/);
      assert.equal(platform.requests.length, 0);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test(`${shell}: --password-stdin with empty input fails`, async () => {
    const platform = await startPlatform({ setupOpen: false });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const result = await run(shell, {
        envFile: writeEnvironment(dir, platform.url),
        email: OPERATOR,
        passwordStdin: true,
        stdin: "",
        skipSetup: true,
        env: { EDK_OPERATOR_PASSWORD: "must-not-be-used" },
      });
      assert.equal(result.code, 1);
      assert.match(result.output, /standard input had no password/);
      assert.equal(platform.requests.length, 0);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test(`${shell}: prompts for the password in a terminal without echoing it`, { skip: !hasScript && "util-linux script is not available" }, async () => {
    const platform = await startPlatform({ setupOpen: false });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const result = await runInTerminal(shell, { envFile: writeEnvironment(dir, platform.url), email: OPERATOR });
      assert.match(result.output, /Password for operator@acme\.example/);
      assert.equal(loginPassword(platform.requests), "typed-at-the-prompt");
      assert.doesNotMatch(result.output, /typed-at-the-prompt/, "the typed password must not be echoed");
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}

if (bash && !isWindows) {
  test("bash: the password never appears on a child process command line", async () => {
    const platform = await startPlatform({ setupOpen: true });
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "provision-contract-"));
    try {
      const bundle = path.join(dir, "license-bundle.zip");
      fs.writeFileSync(bundle, "PK\u0003\u0004bundle");
      // Wrap curl and node so every invocation's arguments are logged.
      const binDir = path.join(dir, "bin");
      fs.mkdirSync(binDir);
      const argLog = path.join(dir, "argv.log");
      for (const tool of ["curl", "node"]) {
        const real = spawnSync("bash", ["-c", `command -v ${tool}`]).stdout.toString().trim();
        fs.writeFileSync(path.join(binDir, tool), `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> '${argLog}'\nexec '${real}' "$@"\n`, { mode: 0o755 });
      }
      await run("bash", {
        envFile: writeEnvironment(dir, platform.url),
        email: OPERATOR,
        passwordStdin: true,
        stdin: "argv-canary-Passw0rd\n",
        licenseBundle: bundle,
        env: { PATH: `${binDir}:${process.env.PATH}` },
      });
      assert.equal(activationPassword(platform.requests), "argv-canary-Passw0rd");
      assert.equal(loginPassword(platform.requests), "argv-canary-Passw0rd");
      assert.doesNotMatch(fs.readFileSync(argLog, "utf8"), /argv-canary-Passw0rd/);
    } finally {
      await platform.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
