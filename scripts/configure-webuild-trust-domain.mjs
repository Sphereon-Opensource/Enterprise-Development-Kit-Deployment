import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TRUST_DOMAIN_API_PATH = "/api/trust-domain/v1";
const CUSTOM_LOTL_FORMAT = "application/xml";
const CUSTOM_LOTL_KIND = "ETSI_119612_CUSTOM_LOTL";
const VALID_MODES = new Set(["eu", "custom", "all"]);

class ConfigurationError extends Error {}
class TrustDomainRequestError extends Error {}

function required(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new ConfigurationError(`Missing required configuration: ${name}`);
  return value;
}

function explicitBoolean(env, name) {
  const value = required(env, name).toLowerCase();
  if (value === "true") return true;
  if (value === "false") return false;
  throw new ConfigurationError(`${name} must be exactly true or false`);
}

function validateIfMatch(value, name) {
  if (value === "*" || /^"(?:[^"\\]|\\.)+"$/u.test(value)) return value;
  throw new ConfigurationError(`${name} must be * or a quoted ETag value`);
}

function validatePathSegment(value, name) {
  if (!/^[A-Za-z0-9._~-]+$/u.test(value)) {
    throw new ConfigurationError(`${name} must be a single URL path segment`);
  }
  return value;
}

function validateApiBaseUrl(value, allowInsecureHttp) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new ConfigurationError("TRUST_DOMAIN_API_BASE_URL must be an absolute URL");
  }
  const normalizedPath = parsed.pathname.replace(/\/+$/u, "");
  if (!parsed.origin || parsed.username || parsed.password || parsed.search || parsed.hash || normalizedPath !== TRUST_DOMAIN_API_PATH) {
    throw new ConfigurationError("TRUST_DOMAIN_API_BASE_URL must end at /api/trust-domain/v1 without query or fragment");
  }
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && allowInsecureHttp)) {
    throw new ConfigurationError("TRUST_DOMAIN_API_BASE_URL must use HTTPS");
  }
  return `${parsed.origin}${TRUST_DOMAIN_API_PATH}`;
}

function parseSignerAnchorIds(env) {
  const raw = required(env, "WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS");
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS must be a JSON array");
  }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.some((value) => typeof value !== "string" || !value.trim())) {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_SIGNER_ANCHOR_IDS must contain at least one non-empty ID");
  }
  return parsed.map((value) => value.trim());
}

function parseCustomConfig(env) {
  const sourceId = validatePathSegment(required(env, "WEBUILD_TRUST_DOMAIN_SOURCE_ID"), "WEBUILD_TRUST_DOMAIN_SOURCE_ID");
  const rawUrl = required(env, "WEBUILD_TRUST_DOMAIN_URL");
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_URL must be an absolute HTTPS URL");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash) {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_URL must use HTTPS without credentials or a fragment");
  }
  const schemeIdentity = required(env, "WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY");
  if (/(?:119\s*602|lote)/iu.test(schemeIdentity)) {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_SCHEME_IDENTITY must identify a TS 119 612 scheme, not a TS 119 602 LoTE role");
  }
  const allowedHost = required(env, "WEBUILD_TRUST_DOMAIN_ALLOWED_HOST").toLowerCase();
  if (!/^[a-z0-9.-]+$/u.test(allowedHost) || url.hostname.toLowerCase() !== allowedHost) {
    throw new ConfigurationError("WEBUILD_TRUST_DOMAIN_ALLOWED_HOST must match the LoTL URL hostname");
  }
  return {
    sourceId,
    url: url.toString(),
    schemeIdentity,
    allowedHost,
    signerAnchorIds: parseSignerAnchorIds(env),
    enabled: explicitBoolean(env, "WEBUILD_TRUST_DOMAIN_ENABLED"),
    ifMatch: validateIfMatch(required(env, "WEBUILD_TRUST_DOMAIN_IF_MATCH"), "WEBUILD_TRUST_DOMAIN_IF_MATCH"),
  };
}

async function readOperatorToken(env) {
  const fromEnvironment = env.TRUST_DOMAIN_OPERATOR_TOKEN?.trim();
  const fromFile = env.TRUST_DOMAIN_OPERATOR_TOKEN_FILE?.trim();
  if (fromEnvironment && fromFile) {
    throw new ConfigurationError("Set only one operator credential source");
  }
  if (fromEnvironment) return fromEnvironment;
  if (!fromFile) throw new ConfigurationError("Missing required configuration: TRUST_DOMAIN_OPERATOR_TOKEN_FILE or TRUST_DOMAIN_OPERATOR_TOKEN");
  try {
    const token = (await readFile(fromFile, "utf8")).trim();
    if (!token) throw new Error("empty");
    return token;
  } catch {
    throw new ConfigurationError("Unable to read the operator credential source");
  }
}

export async function loadConfiguration(env = process.env) {
  const mode = required(env, "TRUST_DOMAIN_BOOTSTRAP_MODE").toLowerCase();
  if (!VALID_MODES.has(mode)) throw new ConfigurationError("TRUST_DOMAIN_BOOTSTRAP_MODE must be eu, custom, or all");
  const allowInsecureHttp = env.TRUST_DOMAIN_ALLOW_INSECURE_HTTP?.trim().toLowerCase() === "true";
  const config = {
    mode,
    apiBaseUrl: validateApiBaseUrl(required(env, "TRUST_DOMAIN_API_BASE_URL"), allowInsecureHttp),
    domainId: validatePathSegment(required(env, "TRUST_DOMAIN_DOMAIN_ID"), "TRUST_DOMAIN_DOMAIN_ID"),
    token: await readOperatorToken(env),
  };

  if (env.TRUST_DOMAIN_EU_URL?.trim()) {
    throw new ConfigurationError("The EU LoTL URL is product-owned and cannot be configured");
  }
  if (mode === "eu" || mode === "all") {
    config.eu = {
      enabled: explicitBoolean(env, "TRUST_DOMAIN_EU_ENABLED"),
      ifMatch: validateIfMatch(required(env, "TRUST_DOMAIN_EU_IF_MATCH"), "TRUST_DOMAIN_EU_IF_MATCH"),
    };
  }
  if (mode === "custom" || mode === "all") config.custom = parseCustomConfig(env);
  return config;
}

function requireResponseEtag(response, action) {
  const etag = response.headers.get("etag")?.trim();
  if (!etag || !/^"(?:[^"\\]|\\.)+"$/u.test(etag)) {
    throw new TrustDomainRequestError(`${action} response did not include a valid ETag`);
  }
  return etag;
}

async function mutation(config, action, method, requestPath, ifMatch, body) {
  const headers = {
    accept: "application/json",
    authorization: `Bearer ${config.token}`,
    "if-match": ifMatch,
  };
  if (body !== undefined) {
    headers["content-type"] = "application/json";
  }
  let response;
  try {
    response = await fetch(`${config.apiBaseUrl}${requestPath}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new TrustDomainRequestError(`${action} request could not be completed`);
  }
  if (!response.ok) {
    throw new TrustDomainRequestError(`${action} request was rejected with HTTP ${response.status}`);
  }
  const etag = requireResponseEtag(response, action);
  const responseText = await response.text();
  let responseBody;
  try {
    responseBody = responseText ? JSON.parse(responseText) : undefined;
  } catch {
    throw new TrustDomainRequestError(`${action} response was not valid JSON`);
  }
  return { body: responseBody, etag };
}

async function configureEu(config) {
  const response = await mutation(
    config,
    "EU trust-source update",
    "PUT",
    `/domains/${encodeURIComponent(config.domainId)}/trust-sources/eu`,
    config.eu.ifMatch,
    { enabled: config.eu.enabled },
  );
  if (response.body?.enabled !== config.eu.enabled) {
    throw new TrustDomainRequestError("EU trust-source response did not confirm the requested enabled state");
  }
  return response;
}

async function configureCustom(config) {
  const custom = config.custom;
  const base = `/domains/${encodeURIComponent(config.domainId)}/trust-sources/custom/${encodeURIComponent(custom.sourceId)}`;
  const candidate = await mutation(config, "WeBuild candidate creation", "PUT", base, custom.ifMatch, {
    url: custom.url,
    format: CUSTOM_LOTL_FORMAT,
    schemeIdentity: custom.schemeIdentity,
    signerAnchorIds: custom.signerAnchorIds,
    egressPolicy: { allowedHosts: [custom.allowedHost] },
    enabled: custom.enabled,
  });
  const revision = candidate.body?.revision;
  if (!Number.isInteger(revision) || revision < 1) {
    throw new TrustDomainRequestError("WeBuild candidate response did not contain a valid revision");
  }
  const revisionBase = `/domains/${encodeURIComponent(config.domainId)}/trust-sources/${encodeURIComponent(custom.sourceId)}/revisions/${revision}`;
  const validated = await mutation(config, "WeBuild candidate validation", "POST", `${revisionBase}/validate`, candidate.etag);
  if (validated.body?.state !== "VALIDATED") {
    throw new TrustDomainRequestError("WeBuild candidate validation did not produce a VALIDATED revision");
  }
  const activated = await mutation(config, "WeBuild candidate activation", "POST", `${revisionBase}/activate`, validated.etag);
  if (activated.body?.revision?.state !== "ACTIVE") {
    throw new TrustDomainRequestError("WeBuild activation did not produce an ACTIVE revision");
  }
  return { revision, etag: activated.etag };
}

export async function configure(env = process.env) {
  const config = await loadConfiguration(env);
  const result = {};
  if (config.eu) result.eu = await configureEu(config);
  if (config.custom) result.custom = await configureCustom(config);
  return result;
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  configure()
    .then((result) => {
      if (result.eu) console.log(`EU trust source ${result.eu.body.enabled ? "enabled" : "disabled"}`);
      if (result.custom) console.log(`WeBuild trust source revision ${result.custom.revision} validated and activated`);
    })
    .catch((error) => {
      const message = error instanceof ConfigurationError || error instanceof TrustDomainRequestError
        ? error.message
        : "Trust-domain configuration failed";
      console.error(message);
      process.exitCode = 1;
    });
}

export { CUSTOM_LOTL_FORMAT, CUSTOM_LOTL_KIND, TRUST_DOMAIN_API_PATH };
