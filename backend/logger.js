// backend/logger.js
// Observabilidade: escreve UMA linha JSON por evento em stdout.
// O Cloud Run coleta stdout; o Cloud Logging coloca o JSON em jsonPayload.
// NUNCA registrar: senha, token, connection string, JWT, cookie,
// texto da tarefa, e-mail ou qualquer dado pessoal.

const SERVICE = process.env.OBS_SERVICE_NAME || "backend";
const ENVIRONMENT = process.env.OBS_ENVIRONMENT || "production";
const PROJECT_ID = process.env.GOOGLE_CLOUD_PROJECT || "";

// Correlação com o request log do Cloud Run via X-Cloud-Trace-Context.
function extractTrace(req) {
  const header = req && req.headers ? req.headers["x-cloud-trace-context"] : null;
  if (!header || !PROJECT_ID) return undefined;
  const traceId = String(header).split("/")[0];
  if (!traceId) return undefined;
  return "projects/" + PROJECT_ID + "/traces/" + traceId;
}

function write(entry) {
  process.stdout.write(JSON.stringify(entry) + "\n");
}

function base(severity, event, extra, req) {
  const entry = Object.assign(
    {
      timestamp: new Date().toISOString(),
      service: SERVICE,
      environment: ENVIRONMENT,
      severity: severity,
      event: event,
    },
    extra || {}
  );
  const trace = extractTrace(req);
  if (trace) entry["logging.googleapis.com/trace"] = trace;
  return entry;
}

// Middleware HTTP: uma linha por requisição concluída.
function httpLogger(req, res, next) {
  const start = process.hrtime.bigint();
  res.on("finish", function () {
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
    const route = (req.baseUrl || "") + (req.route ? req.route.path : req.path);
    const severity =
      res.statusCode >= 500 ? "ERROR" : res.statusCode >= 400 ? "WARNING" : "INFO";
    write(
      base(
        severity,
        "http_request",
        {
          method: req.method,
          route: route,
          status_code: res.statusCode,
          duration_ms: Math.round(durationMs),
          message: req.method + " " + route + " -> " + res.statusCode,
        },
        req
      )
    );
  });
  next();
}

// Evento de operação de banco.
function dbEvent(opts) {
  write(
    base(
      opts.success ? "INFO" : "ERROR",
      "db_operation",
      {
        operation: opts.operation,
        success: opts.success,
        duration_ms: Math.round(opts.durationMs),
        error_type: opts.errorType || undefined,
        message: "db " + opts.operation + " " + (opts.success ? "ok" : "falhou"),
      },
      opts.req
    )
  );
}

// Evento de negócio (SEM conteúdo da tarefa).
function usageEvent(opts) {
  write(
    base("INFO", opts.event, Object.assign({ message: opts.event }, opts.extra || {}), opts.req)
  );
}

// Evento simples de ciclo de vida / erro sem dados sensíveis.
function logEvent(severity, event, message, extra) {
  write(base(severity, event, Object.assign({ message: message }, extra || {})));
}

module.exports = { httpLogger, dbEvent, usageEvent, logEvent };
