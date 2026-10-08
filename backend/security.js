// backend/security.js
// Rotas de DEMONSTRAÇÃO do seminário (Secret Manager e Cloud KMS), em /api/security.
// Só existem com SECURITY_DEMO_ENABLED=true; sem isso, /api/security/* responde 404.
// Nunca devolvem nem registram valor de secret, plaintext ou ciphertext completo:
// só nomes, versões, tamanhos e fingerprints.
//
// Configuração (variáveis de ambiente):
//   GOOGLE_CLOUD_PROJECT  projeto do secret
//   SECRET_NAME           nome curto do secret (ex.: APP_API_KEY)
//   KMS_KEY_NAME          projects/.../locations/.../keyRings/.../cryptoKeys/...

const crypto = require("crypto");
const express = require("express");
const logger = require("./logger");

// Texto fixo cifrado nas rotas de KMS. Não é segredo.
const DEMO_PLAINTEXT = Buffer.from("Triodelicia - demonstracao Cloud KMS", "utf8");

const VERSION_PATTERN = /^(latest|[1-9][0-9]*)$/;
const KMS_KEY_NAME_PATTERN =
  /^projects\/[^/]+\/locations\/[^/]+\/keyRings\/[^/]+\/cryptoKeys\/[^/]+$/;

// Código gRPC -> status HTTP + dica curta. Códigos fora desta tabela -> 500.
const GRPC_ERRORS = {
  7: {
    status: 403,
    error_code: "PERMISSION_DENIED",
    hint: "a service account não tem a role necessária neste recurso (ou a API está desabilitada)",
  },
  16: {
    status: 401,
    error_code: "UNAUTHENTICATED",
    hint: "o backend não conseguiu se autenticar no Google Cloud (credencial ausente ou expirada)",
  },
  5: {
    status: 404,
    error_code: "NOT_FOUND",
    hint: "o secret, a versão ou a chave não existe (confira SECRET_NAME, KMS_KEY_NAME e a versão)",
  },
  9: {
    status: 409,
    error_code: "FAILED_PRECONDITION",
    hint: "o recurso existe, mas não está utilizável (ex.: versão desativada ou destruída)",
  },
  3: {
    status: 422,
    error_code: "INVALID_ARGUMENT",
    hint: "a API rejeitou os dados enviados (ex.: ciphertext alterado ou de outra chave)",
  },
};
const GRPC_NAMES = [
  "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND",
  "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION",
  "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
  "UNAUTHENTICATED",
];

// Erro da própria demo (configuração, integridade), já com status, código e dica.
class DemoError extends Error {
  constructor(status, errorCode, hint) {
    super(errorCode);
    this.name = "DemoError";
    this.status = status;
    this.errorCode = errorCode;
    this.hint = hint;
  }
}

// Nunca usa err.message: ele pode trazer nomes internos ou detalhes da API.
function mapError(err) {
  if (err instanceof DemoError) {
    return { status: err.status, error_code: err.errorCode, hint: err.hint };
  }
  const code = err && typeof err.code === "number" ? err.code : undefined;
  if (GRPC_ERRORS[code]) return Object.assign({}, GRPC_ERRORS[code]);
  return {
    status: 500,
    error_code: GRPC_NAMES[code] || "INTERNAL",
    hint: "erro inesperado ao chamar a API do Google Cloud",
  };
}

// CRC32C (Castagnoli): checksum que o KMS e o Secret Manager usam para integridade.
const CRC32C_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0x82f63b78 ^ (c >>> 1) : c >>> 1;
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32c(data) {
  let crc = 0xffffffff;
  for (const byte of data) crc = CRC32C_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

// int64 da API: string (gax usa longs: String), número, Long ou wrapper { value }.
function int64ToNumber(v) {
  if (v === null || v === undefined) return undefined;
  if (typeof v === "object" && "value" in v) return int64ToNumber(v.value);
  if (typeof v === "object" && typeof v.toNumber === "function") return v.toNumber();
  return Number(v);
}

function integrityError() {
  return new DemoError(
    500,
    "INTEGRITY_CHECK_FAILED",
    "checksum CRC32C não confere: dados corrompidos entre o backend e a API; tente de novo"
  );
}

function lastSegmentAsNumber(name) {
  const n = Number(String(name || "").split("/").pop());
  return Number.isInteger(n) ? n : undefined;
}

function fingerprint(data) {
  return crypto.createHash("sha256").update(data).digest("hex").slice(0, 8);
}

function sha256Hex(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function readConfig(env) {
  return {
    projectId: env.GOOGLE_CLOUD_PROJECT || "",
    secretName: env.SECRET_NAME || "",
    kmsKeyName: env.KMS_KEY_NAME || "",
  };
}

// Cronometra uma chamada à API e registra um securityEvent (sucesso ou falha).
async function observed(req, opts, fn) {
  const start = process.hrtime.bigint();
  const elapsed = () => Number(process.hrtime.bigint() - start) / 1e6;
  try {
    const result = await fn();
    logger.securityEvent(
      Object.assign(
        { event: opts.event, operation: opts.operation, success: true, durationMs: elapsed(), req },
        opts.fields(result)
      )
    );
    return result;
  } catch (err) {
    const mapped = mapError(err);
    logger.securityEvent(
      Object.assign(
        {
          event: opts.event,
          operation: opts.operation,
          success: false,
          errorCode: mapped.error_code,
          httpStatus: mapped.status,
          durationMs: elapsed(),
          req,
        },
        opts.failFields || {}
      )
    );
    throw err;
  }
}

function sendError(res, err) {
  const mapped = mapError(err);
  res.status(mapped.status).json({ ok: false, error_code: mapped.error_code, hint: mapped.hint });
}

// Express 4 não trata rejeição de handler async: converte em resposta mapeada.
const route = (handler) => (req, res) => handler(req, res).catch((err) => sendError(res, err));

function createSecurityRouter(options) {
  const opts = options || {};
  const config = readConfig(opts.env || process.env);

  // Clientes injetáveis (testes). Os padrões só são carregados aqui, com a demo ativa:
  // com ela desligada, o backend nem importa as bibliotecas do Google.
  const secretClient =
    opts.secretClient ||
    new (require("@google-cloud/secret-manager").SecretManagerServiceClient)();
  const kmsClient =
    opts.kmsClient || new (require("@google-cloud/kms").KeyManagementServiceClient)();

  function requireSecretConfig() {
    if (!config.projectId || !config.secretName) {
      throw new DemoError(500, "CONFIG_MISSING", "defina GOOGLE_CLOUD_PROJECT e SECRET_NAME no serviço");
    }
  }

  function requireKmsConfig() {
    if (!KMS_KEY_NAME_PATTERN.test(config.kmsKeyName)) {
      throw new DemoError(
        500,
        "CONFIG_MISSING",
        "defina KMS_KEY_NAME com o nome completo projects/.../cryptoKeys/..."
      );
    }
  }

  async function encryptDemo() {
    const [response] = await kmsClient.encrypt({
      name: config.kmsKeyName,
      plaintext: DEMO_PLAINTEXT,
      plaintextCrc32c: { value: crc32c(DEMO_PLAINTEXT) },
    });
    const ciphertext = Buffer.from(response.ciphertext || []);
    if (
      !response.verifiedPlaintextCrc32c ||
      int64ToNumber(response.ciphertextCrc32c) !== crc32c(ciphertext)
    ) {
      throw integrityError();
    }
    return { ciphertext, keyVersion: lastSegmentAsNumber(response.name) };
  }

  async function decrypt(ciphertext) {
    const [response] = await kmsClient.decrypt({
      name: config.kmsKeyName,
      ciphertext,
      ciphertextCrc32c: { value: crc32c(ciphertext) },
    });
    const plaintext = Buffer.from(response.plaintext || []);
    if (int64ToNumber(response.plaintextCrc32c) !== crc32c(plaintext)) {
      throw integrityError();
    }
    return plaintext;
  }

  const router = express.Router();

  router.get("/status", (req, res) => {
    res.json({
      ok: true,
      enabled: true,
      project: config.projectId || null,
      secret: config.secretName || null,
      kmsKey: config.kmsKeyName || null,
    });
  });

  router.get(
    "/secret",
    route(async (req, res) => {
      const requested = req.query.version === undefined ? "latest" : String(req.query.version);
      if (!VERSION_PATTERN.test(requested)) {
        throw new DemoError(400, "INVALID_VERSION", 'version deve ser "latest" ou um número inteiro positivo');
      }
      requireSecretConfig();

      // SEM CACHE, de propósito: accessSecretVersion roda a cada requisição para que a
      // revogação da role no IAM apareça ao vivo na demo. Em produção se usaria cache
      // com TTL ou o secret montado pelo Cloud Run (--set-secrets).
      const name = `projects/${config.projectId}/secrets/${config.secretName}/versions/${requested}`;
      const result = await observed(
        req,
        {
          event: "secret_access",
          operation: "access",
          fields: (r) => ({ secretVersion: r.version }),
          failFields: { secretVersion: requested },
        },
        async () => {
          const [response] = await secretClient.accessSecretVersion({ name });
          const data = Buffer.from((response.payload && response.payload.data) || []);
          const expectedCrc = int64ToNumber(response.payload && response.payload.dataCrc32c);
          if (expectedCrc !== undefined && expectedCrc !== crc32c(data)) throw integrityError();
          return { data, version: lastSegmentAsNumber(response.name) };
        }
      );

      res.json({
        ok: true,
        secret: config.secretName,
        version: result.version,
        length: result.data.length,
        fingerprint: fingerprint(result.data),
      });
    })
  );

  router.get(
    "/kms/roundtrip",
    route(async (req, res) => {
      requireKmsConfig();
      res.set("Cache-Control", "no-store");

      const encrypted = await observed(
        req,
        { event: "kms_operation", operation: "encrypt", fields: (r) => ({ keyVersion: r.keyVersion }) },
        () => encryptDemo()
      );
      const plaintext = await observed(
        req,
        {
          event: "kms_operation",
          operation: "decrypt",
          fields: () => ({ keyVersion: encrypted.keyVersion }),
          failFields: { keyVersion: encrypted.keyVersion },
        },
        () => decrypt(encrypted.ciphertext)
      );

      const ciphertextHash = sha256Hex(encrypted.ciphertext);

      res.json({
        ok: true,
        operation: "kms_roundtrip",
        keyVersion: encrypted.keyVersion,
        ciphertextLength: encrypted.ciphertext.length,
        ciphertextHash: {
          algorithm: "SHA-256",
          length: ciphertextHash.length,
          value: ciphertextHash,
        },
        decryption: "accepted",
        roundtripMatch: plaintext.equals(DEMO_PLAINTEXT),
      });
    })
  );

  router.get(
    "/kms/tamper",
    route(async (req, res) => {
      requireKmsConfig();
      res.set("Cache-Control", "no-store");

      const encrypted = await observed(
        req,
        { event: "kms_operation", operation: "encrypt", fields: (r) => ({ keyVersion: r.keyVersion }) },
        () => encryptDemo()
      );

      // Altera 1 bit do último byte (fim do ciphertext autenticado). O CRC32C é
      // recalculado sobre os bytes adulterados: assim o KMS não recusa por checksum de
      // transporte, e sim porque a autenticação do ciphertext falha (INVALID_ARGUMENT).
      const tampered = Buffer.from(encrypted.ciphertext);
      tampered[tampered.length - 1] ^= 0x01;

      const originalCiphertextHash = sha256Hex(encrypted.ciphertext);
      const tamperedCiphertextHash = sha256Hex(tampered);

      try {
        await observed(
          req,
          {
            event: "kms_operation",
            operation: "decrypt_tampered",
            fields: () => ({ keyVersion: encrypted.keyVersion }),
            failFields: { keyVersion: encrypted.keyVersion },
          },
          () => decrypt(tampered)
        );
      } catch (err) {
        if (mapError(err).error_code === "INVALID_ARGUMENT") {
          return res.status(422).json({
            ok: false,
            operation: "kms_tamper",
            keyVersion: encrypted.keyVersion,
            ciphertextLength: encrypted.ciphertext.length,
            ciphertextHash: {
              algorithm: "SHA-256",
              length: originalCiphertextHash.length,
              original: originalCiphertextHash,
              tampered: tamperedCiphertextHash,
            },
            decryption: "rejected",
            tamperDetected: true,
            error_code: "INVALID_ARGUMENT",
          });
        }
        throw err;
      }

      throw new DemoError(500, "TAMPER_NOT_DETECTED", "o KMS aceitou um ciphertext alterado; isso não deveria acontecer");
    })
  );

  return router;
}

// Monta /api/security só com SECURITY_DEMO_ENABLED=true. Devolve se montou.
function mountSecurityDemo(app, env, deps) {
  const environment = env || process.env;
  if (environment.SECURITY_DEMO_ENABLED !== "true") return false;
  app.use("/api/security", createSecurityRouter(Object.assign({ env: environment }, deps || {})));
  // O backend é público via Load Balancer: deixar ativo só durante a apresentação.
  logger.logEvent("WARNING", "security_demo_enabled", "Rotas de demonstração ativas em /api/security");
  return true;
}

module.exports = { mountSecurityDemo, createSecurityRouter, mapError, crc32c };
