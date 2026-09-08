import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "configure-webuild-trust-domain.mjs");
const operatorToken = "operator-token-must-never-be-logged";

async function startFakeServer(handler) {
  const requests = [];
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const rawBody = Buffer.concat(chunks).toString("utf8");
    const record = {
      method: request.method,
      path: request.url,
      headers: request.headers,
      rawBody,
      body: rawBody ? JSON.parse(rawBody) : undefined,
    };
    requests.push(record);
    const result = await handler(record, requests);
    response.writeHead(result.status ?? 200, result.headers ?? { "content-type": "application/json" });
    response.end(result.body === undefined ? "{}" : JSON.stringify(result.body));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  return { server, requests, baseUrl: `http://127.0.0.1:${port}/api/trust-domain/v1` };
}

async function runScript(baseUrl, overrides = {}) {
  const child = spawn(process.execPath, [scriptPath], {
    env: {
      ...process.env,
      TRUST_DOMAIN_API_BASE_URL: baseUrl,
      TRUST_DOMAIN_ALLOW_INSECURE_HTTP: "true",
      TRUST_DOMAIN_DOMAIN_ID: "operator-supplied-domain",
      TRUST_DOMAIN_OPERATOR_TOKEN: operatorToken,
      TRUST_DOMAIN_BOOTSTRAP_MODE: "custom",
      WEBUILD_TRUST_DOMAIN_SOURCE_ID: "webuild-test-source",
      WEBUILD_TRUST_DOMAIN_URL: "https://operator-supplied.example.test/lists/consortium.xml",
      WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY: "https://operator-supplied.example.test/scheme",
      WEBUILD_TRUST_DOMAIN_ALLOWED_HOST: "operator-supplied.example.test",
      WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS: "[\"operator-supplied-signer-anchor\"]",
      WEBUILD_TRUST_DOMAIN_ENABLED: "true",
      WEBUILD_TRUST_DOMAIN_IF_MATCH: '"source-v1"',
      ...overrides,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const [stdout, stderr] = await Promise.all([
    new Promise((resolve) => {
      let value = "";
      child.stdout.on("data", (chunk) => { value += chunk; });
      child.stdout.on("end", () => resolve(value));
    }),
    new Promise((resolve) => {
      let value = "";
      child.stderr.on("data", (chunk) => { value += chunk; });
      child.stderr.on("end", () => resolve(value));
    }),
  ]);
  const exitCode = await new Promise((resolve) => child.on("close", resolve));
  return { exitCode, stdout, stderr, output: `${stdout}${stderr}` };
}

function closeServer(server) {
  return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

function revision(state, revisionNumber = 1) {
  return {
    sourceId: "webuild-test-source",
    domainId: "operator-supplied-domain",
    kind: "ETSI_119612_CUSTOM_LOTL",
    revision: revisionNumber,
    state,
  };
}

test("missing WeBuild configuration performs zero HTTP mutations and does not log the token", async () => {
  const fake = await startFakeServer(() => ({ status: 500 }));
  try {
    const result = await runScript(fake.baseUrl, {
      WEBUILD_TRUST_DOMAIN_URL: "",
      WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY: "",
      WEBUILD_TRUST_DOMAIN_ALLOWED_HOST: "",
      WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS: "",
      WEBUILD_TRUST_DOMAIN_IF_MATCH: "",
    });
    assert.notEqual(result.exitCode, 0);
    assert.equal(fake.requests.length, 0);
    assert.equal(result.output.includes(operatorToken), false);
  } finally {
    await closeServer(fake.server);
  }
});

test("each missing required WeBuild input fails before any HTTP mutation", async (t) => {
  const cases = [
    ["URL", { WEBUILD_TRUST_DOMAIN_URL: "" }],
    ["scheme identity", { WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY: "" }],
    ["allowed host", { WEBUILD_TRUST_DOMAIN_ALLOWED_HOST: "" }],
    ["pinned signer anchors", { WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS: "" }],
    ["If-Match", { WEBUILD_TRUST_DOMAIN_IF_MATCH: "" }],
    ["operator credential", { TRUST_DOMAIN_OPERATOR_TOKEN: "", TRUST_DOMAIN_OPERATOR_TOKEN_FILE: "" }],
  ];
  for (const [name, overrides] of cases) {
    await t.test(name, async () => {
      const fake = await startFakeServer(() => ({ status: 500 }));
      try {
        const result = await runScript(fake.baseUrl, overrides);
        assert.notEqual(result.exitCode, 0);
        assert.equal(fake.requests.length, 0);
        assert.equal(result.output.includes(operatorToken), false);
      } finally {
        await closeServer(fake.server);
      }
    });
  }
});

test("EU flow sends only the explicit enabled flag and never accepts a URL", async () => {
  const fake = await startFakeServer((request) => {
    assert.equal(request.method, "PUT");
    assert.equal(request.path, "/api/trust-domain/v1/domains/operator-supplied-domain/trust-sources/eu");
    assert.deepEqual(request.body, { enabled: true });
    assert.equal(request.headers["if-match"], '"eu-v1"');
    assert.equal(request.headers.authorization, `Bearer ${operatorToken}`);
    return { headers: { "content-type": "application/json", etag: '"eu-v2"' }, body: { enabled: true } };
  });
  try {
    const result = await runScript(fake.baseUrl, {
      TRUST_DOMAIN_BOOTSTRAP_MODE: "eu",
      TRUST_DOMAIN_EU_ENABLED: "true",
      TRUST_DOMAIN_EU_IF_MATCH: '"eu-v1"',
    });
    assert.equal(result.exitCode, 0, result.output);
    assert.equal(fake.requests.length, 1);
    assert.equal(fake.requests[0].rawBody.includes("url"), false);
  } finally {
    await closeServer(fake.server);
  }
});

test("an attempted EU URL override is rejected before any mutation", async () => {
  const fake = await startFakeServer(() => ({ status: 500 }));
  try {
    const result = await runScript(fake.baseUrl, {
      TRUST_DOMAIN_BOOTSTRAP_MODE: "eu",
      TRUST_DOMAIN_EU_ENABLED: "true",
      TRUST_DOMAIN_EU_IF_MATCH: '"eu-v1"',
      TRUST_DOMAIN_EU_URL: "https://must-not-be-accepted.example.test/eu.xml",
    });
    assert.notEqual(result.exitCode, 0);
    assert.equal(fake.requests.length, 0);
  } finally {
    await closeServer(fake.server);
  }
});

test("custom flow rejects non-HTTPS, host-mismatched, and TS 119 602 role-confused material before mutation", async (t) => {
  const cases = [
    ["non-HTTPS URL", { WEBUILD_TRUST_DOMAIN_URL: "http://operator-supplied.example.test/list.xml" }],
    ["host mismatch", { WEBUILD_TRUST_DOMAIN_ALLOWED_HOST: "different.example.test" }],
    ["TS 119 602 role", { WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY: "TS 119 602 LoTE QEAA" }],
  ];
  for (const [name, overrides] of cases) {
    await t.test(name, async () => {
      const fake = await startFakeServer(() => ({ status: 500 }));
      try {
        const result = await runScript(fake.baseUrl, overrides);
        assert.notEqual(result.exitCode, 0);
        assert.equal(fake.requests.length, 0);
        assert.equal(result.output.includes(operatorToken), false);
      } finally {
        await closeServer(fake.server);
      }
    });
  }
});

test("custom flow sends the HTTPS URL, scheme, allowed host, and pinned signer references, then validates before activation", async () => {
  const fake = await startFakeServer((request, requests) => {
    if (requests.length === 1) {
      return { headers: { "content-type": "application/json", etag: '"candidate-v2"' }, body: revision("DRAFT", 2) };
    }
    if (requests.length === 2) {
      return { headers: { "content-type": "application/json", etag: '"validated-v2"' }, body: revision("VALIDATED", 2) };
    }
    return {
      headers: { "content-type": "application/json", etag: '"active-v2"' },
      body: { source: { sourceId: "webuild-test-source", enabled: true }, revision: revision("ACTIVE", 2) },
    };
  });
  try {
    const result = await runScript(fake.baseUrl);
    assert.equal(result.exitCode, 0, result.output);
    assert.deepEqual(fake.requests.map(({ method, path: requestPath }) => [method, requestPath]), [
      ["PUT", "/api/trust-domain/v1/domains/operator-supplied-domain/trust-sources/custom/webuild-test-source"],
      ["POST", "/api/trust-domain/v1/domains/operator-supplied-domain/trust-sources/webuild-test-source/revisions/2/validate"],
      ["POST", "/api/trust-domain/v1/domains/operator-supplied-domain/trust-sources/webuild-test-source/revisions/2/activate"],
    ]);
    assert.deepEqual(fake.requests[0].body, {
      url: "https://operator-supplied.example.test/lists/consortium.xml",
      format: "application/xml",
      schemeIdentity: "https://operator-supplied.example.test/scheme",
      signerAnchorIds: ["operator-supplied-signer-anchor"],
      egressPolicy: { allowedHosts: ["operator-supplied.example.test"] },
      enabled: true,
    });
    assert.equal(fake.requests[0].body.kind, undefined);
    assert.doesNotMatch(JSON.stringify(fake.requests[0].body), /119602|LoTE/u);
    assert.deepEqual(fake.requests.map((request) => request.headers["if-match"]), [
      '"source-v1"',
      '"candidate-v2"',
      '"validated-v2"',
    ]);
    assert.equal(result.output.includes(operatorToken), false);
  } finally {
    await closeServer(fake.server);
  }
});

test("a wildcard candidate response ETag stops before validation or activation", async () => {
  const fake = await startFakeServer((request, requests) => {
    if (requests.length === 1) {
      return { headers: { "content-type": "application/json", etag: "*" }, body: revision("DRAFT", 2) };
    }
    if (requests.length === 2) {
      return { headers: { "content-type": "application/json", etag: '"validated-v2"' }, body: revision("VALIDATED", 2) };
    }
    return {
      headers: { "content-type": "application/json", etag: '"active-v2"' },
      body: { source: { sourceId: "webuild-test-source", enabled: true }, revision: revision("ACTIVE", 2) },
    };
  });
  try {
    const result = await runScript(fake.baseUrl);
    assert.notEqual(result.exitCode, 0);
    assert.deepEqual(fake.requests.map(({ method, path: requestPath }) => [method, requestPath]), [
      ["PUT", "/api/trust-domain/v1/domains/operator-supplied-domain/trust-sources/custom/webuild-test-source"],
    ]);
  } finally {
    await closeServer(fake.server);
  }
});

test("a missing response ETag stops before validation or activation", async () => {
  const fake = await startFakeServer(() => ({ body: revision("DRAFT", 2) }));
  try {
    const result = await runScript(fake.baseUrl);
    assert.notEqual(result.exitCode, 0);
    assert.equal(fake.requests.length, 1);
  } finally {
    await closeServer(fake.server);
  }
});

test("401, 403, 409, and 412 stop the custom flow before later mutations", async (t) => {
  for (const status of [401, 403, 409, 412]) {
    await t.test(`status ${status}`, async () => {
      const fake = await startFakeServer(() => ({ status, body: { error: "redacted" } }));
      try {
        const result = await runScript(fake.baseUrl);
        assert.notEqual(result.exitCode, 0);
        assert.equal(fake.requests.length, 1);
        assert.equal(result.output.includes(operatorToken), false);
      } finally {
        await closeServer(fake.server);
      }
    });
  }
});

test("validation failure stops before activation", async () => {
  const fake = await startFakeServer((request, requests) => {
    if (requests.length === 1) {
      return { headers: { "content-type": "application/json", etag: '"candidate-v2"' }, body: revision("DRAFT", 2) };
    }
    return { status: 422, body: { error: "validation material rejected" } };
  });
  try {
    const result = await runScript(fake.baseUrl);
    assert.notEqual(result.exitCode, 0);
    assert.equal(fake.requests.length, 2);
    assert.equal(fake.requests[1].path.endsWith("/validate"), true);
  } finally {
    await closeServer(fake.server);
  }
});
