// Testes das rotas de demonstração (backend/security.js) com clientes falsos:
// nenhuma chamada real ao Google Cloud.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { once } = require("node:events");
const express = require("express");
const { mountSecurityDemo, crc32c } = require("../security");

const ENV = {
  SECURITY_DEMO_ENABLED: "true",
  GOOGLE_CLOUD_PROJECT: "projeto-teste",
  SECRET_NAME: "APP_API_KEY",
  KMS_KEY_NAME: "projects/projeto-teste/locations/southamerica-east1/keyRings/kr/cryptoKeys/chave",
};
const SECRET_VALUE = "valor-de-teste-que-nunca-pode-vazar";
const DETALHE_INTERNO = "detalhe-interno-da-api-que-nao-pode-vazar";

// --- Captura das linhas JSON do logger (o resto do stdout passa direto) -------------
const logs = [];
const originalWrite = process.stdout.write;
process.stdout.write = function (chunk, ...rest) {
  if (typeof chunk === "string" && chunk.startsWith('{"timestamp"')) {
    logs.push(JSON.parse(chunk));
    return true;
  }
  return originalWrite.call(process.stdout, chunk, ...rest);
};
test.after(() => {
  process.stdout.write = originalWrite;
});
const securityLogs = () => logs.filter((l) => l.event === "secret_access" || l.event === "kms_operation");

// --- Clientes falsos ------------------------------------------------------------------
function grpcError(code) {
  return Object.assign(new Error(DETALHE_INTERNO), { code });
}

function fakeSecretClient(behavior = {}) {
  const calls = [];
  return {
    calls,
    async accessSecretVersion({ name }) {
      calls.push(name);
      if (behavior.fail) throw behavior.fail;
      const requested = name.split("/").pop();
      const version = requested === "latest" ? 3 : Number(requested);
      const data = Buffer.from(SECRET_VALUE);
      const crc = behavior.badCrc ? crc32c(data) ^ 1 : crc32c(data);
      return [
        {
          name: `projects/123456/secrets/APP_API_KEY/versions/${version}`,
          payload: { data, dataCrc32c: String(crc) },
        },
      ];
    },
  };
}

// "Cifra" XOR + tag (SHA-256 truncado): imita o que se observa do KMS. Sem a chave,
// qualquer byte alterado invalida a tag e o decrypt falha com INVALID_ARGUMENT (3).
function fakeKmsClient(behavior = {}) {
  const sha = (b) => crypto.createHash("sha256").update(b).digest().subarray(0, 8);
  const xor = (b) => Buffer.from(Buffer.from(b).map((x) => x ^ 0x5a));
  return {
    async encrypt({ name, plaintext, plaintextCrc32c }) {
      if (behavior.failEncrypt) throw behavior.failEncrypt;
      const body = xor(plaintext);
      const ciphertext = Buffer.concat([body, sha(body)]);
      return [
        {
          name: `${name}/cryptoKeyVersions/1`,
          ciphertext,
          ciphertextCrc32c: { value: String(crc32c(ciphertext)) },
          verifiedPlaintextCrc32c: Number(plaintextCrc32c.value) === crc32c(Buffer.from(plaintext)),
        },
      ];
    },
    async decrypt({ ciphertext, ciphertextCrc32c }) {
      if (behavior.failDecrypt) throw behavior.failDecrypt;
      const ct = Buffer.from(ciphertext);
      if (Number(ciphertextCrc32c.value) !== crc32c(ct)) throw grpcError(3);
      const body = ct.subarray(0, -8);
      if (!sha(body).equals(ct.subarray(-8))) throw grpcError(3);
      const plaintext = xor(body);
      return [{ plaintext, plaintextCrc32c: { value: String(crc32c(plaintext)) } }];
    },
  };
}

// --- Servidor de teste ----------------------------------------------------------------
async function withApp(env, deps, fn) {
  const app = express();
  const mounted = mountSecurityDemo(app, env, deps);
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const base = `http://127.0.0.1:${server.address().port}`;
  logs.length = 0;
  try {
    return await fn(base, mounted);
  } finally {
    server.close();
  }
}

async function call(base, method, path) {
  const res = await fetch(base + path, { method });
  const text = await res.text();
  return { status: res.status, text, body: text.startsWith("{") ? JSON.parse(text) : null };
}

function assertNoLeak(text) {
  assert.ok(!text.includes(SECRET_VALUE), "o valor do secret vazou");
  assert.ok(!text.includes(DETALHE_INTERNO), "err.message vazou");
}

const deps = (secret = {}, kms = {}) => ({
  secretClient: fakeSecretClient(secret),
  kmsClient: fakeKmsClient(kms),
});

// --- Testes -----------------------------------------------------------------------------
test("crc32c confere com o vetor de referência (\"123456789\" -> 0xE3069283)", () => {
  assert.equal(crc32c(Buffer.from("123456789")), 0xe3069283);
});

test("demo desligada: /api/security/* não existe (404)", async () => {
  for (const flag of [undefined, "false", "TRUE", "1"]) {
    await withApp({ ...ENV, SECURITY_DEMO_ENABLED: flag }, deps(), async (base, mounted) => {
      assert.equal(mounted, false);
      assert.equal((await call(base, "GET", "/api/security/status")).status, 404);
      assert.equal((await call(base, "GET", "/api/security/secret")).status, 404);
      assert.equal((await call(base, "POST", "/api/security/kms/roundtrip")).status, 404);
    });
  }
});

test("status: demo ativa e só os NOMES configurados", async () => {
  await withApp(ENV, deps(), async (base) => {
    const r = await call(base, "GET", "/api/security/status");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, {
      ok: true,
      enabled: true,
      project: "projeto-teste",
      secret: "APP_API_KEY",
      kmsKey: ENV.KMS_KEY_NAME,
    });
  });
});

test("secret: sucesso devolve versão lida, tamanho e fingerprint, nunca o valor", async () => {
  const d = deps();
  await withApp(ENV, d, async (base) => {
    const r = await call(base, "GET", "/api/security/secret");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, {
      ok: true,
      secret: "APP_API_KEY",
      version: 3,
      length: Buffer.byteLength(SECRET_VALUE),
      fingerprint: crypto.createHash("sha256").update(SECRET_VALUE).digest("hex").slice(0, 8),
    });
    assertNoLeak(r.text);
    assert.deepEqual(d.secretClient.calls, ["projects/projeto-teste/secrets/APP_API_KEY/versions/latest"]);

    const [log] = securityLogs();
    assert.equal(log.event, "secret_access");
    assert.equal(log.severity, "INFO");
    assert.equal(log.success, true);
    assert.equal(log.secret_version, 3);
    assertNoLeak(JSON.stringify(logs));
  });
});

test("secret: sem cache, cada requisição chama a API; version numérica é repassada", async () => {
  const d = deps();
  await withApp(ENV, d, async (base) => {
    await call(base, "GET", "/api/security/secret");
    const r = await call(base, "GET", "/api/security/secret?version=2");
    assert.equal(r.body.version, 2);
    assert.equal(d.secretClient.calls.length, 2);
    assert.match(d.secretClient.calls[1], /\/versions\/2$/);
  });
});

test("secret: version inválida -> 400 sem chamar a API", async () => {
  const d = deps();
  await withApp(ENV, d, async (base) => {
    for (const v of ["abc", "0", "-1", "1.5", "LATEST", "latest/../1", "", "1&version=2"]) {
      const r = await call(base, "GET", "/api/security/secret?version=" + encodeURIComponent(v));
      assert.equal(r.status, 400, `version=${v}`);
      assert.equal(r.body.error_code, "INVALID_VERSION");
    }
    const dupla = await call(base, "GET", "/api/security/secret?version=1&version=2");
    assert.equal(dupla.status, 400);
    assert.equal(d.secretClient.calls.length, 0);
  });
});

test("secret: PERMISSION_DENIED -> 403 com dica, sem err.message, log WARNING", async () => {
  await withApp(ENV, deps({ fail: grpcError(7) }), async (base) => {
    const r = await call(base, "GET", "/api/security/secret");
    assert.equal(r.status, 403);
    assert.deepEqual(r.body, {
      ok: false,
      error_code: "PERMISSION_DENIED",
      hint: "a service account não tem a role necessária neste recurso (ou a API está desabilitada)",
    });
    assertNoLeak(r.text);

    const [log] = securityLogs();
    assert.equal(log.severity, "WARNING");
    assert.equal(log.success, false);
    assert.equal(log.error_code, "PERMISSION_DENIED");
    assert.equal(log.secret_version, "latest");
    assertNoLeak(JSON.stringify(logs));
  });
});

test("secret: FAILED_PRECONDITION (versão desativada) -> 409", async () => {
  await withApp(ENV, deps({ fail: grpcError(9) }), async (base) => {
    const r = await call(base, "GET", "/api/security/secret?version=1");
    assert.equal(r.status, 409);
    assert.equal(r.body.error_code, "FAILED_PRECONDITION");
    assert.equal(securityLogs()[0].severity, "WARNING");
    assertNoLeak(r.text);
  });
});

test("mapeamento gRPC: UNAUTHENTICATED 401, NOT_FOUND 404; outros -> 500 com log ERROR", async () => {
  const casos = [
    [16, 401, "UNAUTHENTICATED", "WARNING"],
    [5, 404, "NOT_FOUND", "WARNING"],
    [14, 500, "UNAVAILABLE", "ERROR"],
  ];
  for (const [code, status, errorCode, severity] of casos) {
    await withApp(ENV, deps({ fail: grpcError(code) }), async (base) => {
      const r = await call(base, "GET", "/api/security/secret");
      assert.equal(r.status, status);
      assert.equal(r.body.error_code, errorCode);
      assert.equal(securityLogs()[0].severity, severity);
      assertNoLeak(r.text);
    });
  }
});

test("secret: CRC32C divergente -> 500 INTEGRITY_CHECK_FAILED", async () => {
  await withApp(ENV, deps({ badCrc: true }), async (base) => {
    const r = await call(base, "GET", "/api/security/secret");
    assert.equal(r.status, 500);
    assert.equal(r.body.error_code, "INTEGRITY_CHECK_FAILED");
    assertNoLeak(r.text);
  });
});

test("kms/roundtrip: cifra e decifra, devolve versão da chave e só um preview", async () => {
  await withApp(ENV, deps(), async (base) => {
    const r = await call(base, "POST", "/api/security/kms/roundtrip");
    assert.equal(r.status, 200);
    assert.equal(r.body.ok, true);
    assert.equal(r.body.keyVersion, 1);
    assert.equal(r.body.roundtripMatch, true);
    assert.equal(typeof r.body.ciphertextLength, "number");
    assert.match(r.body.ciphertextPreview, /^[A-Za-z0-9+/=]{12}\.\.\.$/);

    const ops = securityLogs().map((l) => [l.event, l.operation, l.severity, l.key_version]);
    assert.deepEqual(ops, [
      ["kms_operation", "encrypt", "INFO", 1],
      ["kms_operation", "decrypt", "INFO", 1],
    ]);
  });
});

test("kms/tamper: 1 byte alterado -> INVALID_ARGUMENT do KMS (422), log WARNING", async () => {
  await withApp(ENV, deps(), async (base) => {
    const r = await call(base, "POST", "/api/security/kms/tamper");
    assert.equal(r.status, 422);
    assert.equal(r.body.ok, false);
    assert.equal(r.body.error_code, "INVALID_ARGUMENT");
    assert.match(r.body.hint, /adulteração detectada/);
    assertNoLeak(r.text);

    const tamper = securityLogs().find((l) => l.operation === "decrypt_tampered");
    assert.equal(tamper.severity, "WARNING");
    assert.equal(tamper.error_code, "INVALID_ARGUMENT");
    assert.equal(tamper.key_version, 1);
  });
});

test("kms: PERMISSION_DENIED no encrypt -> 403", async () => {
  await withApp(ENV, deps({}, { failEncrypt: grpcError(7) }), async (base) => {
    for (const path of ["/api/security/kms/roundtrip", "/api/security/kms/tamper"]) {
      const r = await call(base, "POST", path);
      assert.equal(r.status, 403);
      assert.equal(r.body.error_code, "PERMISSION_DENIED");
      assertNoLeak(r.text);
    }
  });
});

test("kms: KMS_KEY_NAME ausente ou incompleto -> 500 CONFIG_MISSING sem chamar a API", async () => {
  for (const nome of [undefined, "seminario-chave"]) {
    await withApp({ ...ENV, KMS_KEY_NAME: nome }, deps({}, { failEncrypt: new Error("não deveria chamar") }), async (base) => {
      const r = await call(base, "POST", "/api/security/kms/roundtrip");
      assert.equal(r.status, 500);
      assert.equal(r.body.error_code, "CONFIG_MISSING");
      assert.equal(securityLogs().length, 0);
    });
  }
});
