const express = require("express");
const mongoose = require("mongoose");
const cors = require("cors");
const bodyParser = require("body-parser");
const logger = require("./logger");
const { mountSecurityDemo } = require("./security");

const app = express();
const port = process.env.PORT || 5000;

// Conexão com o banco. Em produção (Cloud Run) a URI é montada a partir das
// variáveis FIRESTORE_* e autentica via MONGODB-OIDC: sem senha, com a identidade
// da service account do serviço. MONGO_URI é só para o ambiente local
// (docker-compose monta a URI a partir do .env).
const FIRESTORE_ENV_VARS = ["FIRESTORE_DB_UID", "FIRESTORE_DB_LOCATION", "FIRESTORE_DB_ID"];
const isProduction = (process.env.OBS_ENVIRONMENT || "production") === "production";

function resolveMongoUri() {
  if (process.env.MONGO_URI) {
    if (isProduction) {
      // Só o NOME da variável; nunca o valor.
      logger.logEvent(
        "WARNING",
        "config_warning",
        "MONGO_URI definida em produção: ela tem prioridade e anula a autenticação OIDC",
        { env_var: "MONGO_URI" }
      );
    }
    return process.env.MONGO_URI;
  }

  const missing = FIRESTORE_ENV_VARS.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    logger.logEvent(
      "ERROR",
      "config_error",
      "Configuração do banco ausente: defina as variáveis FIRESTORE_* (ou MONGO_URI no ambiente local)",
      { missing_env: missing }
    );
    process.exit(1);
  }

  return `mongodb://${process.env.FIRESTORE_DB_UID}.${process.env.FIRESTORE_DB_LOCATION}.firestore.goog:443/${process.env.FIRESTORE_DB_ID}?loadBalanced=true&tls=true&retryWrites=false&authMechanism=MONGODB-OIDC&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE`;
}

const mongoUri = resolveMongoUri();

mongoose
  .connect(mongoUri)
  .then(() => logger.logEvent("INFO", "startup", "Conectado ao banco de dados"))
  .catch((err) => {
    // NÃO logar o objeto de erro inteiro: ele pode conter a connection string.
    logger.logEvent("ERROR", "startup_error", "Falha ao conectar ao banco", {
      error_type: err.name || "Error",
    });
    process.exit(1);
  });

app.use(cors());
app.use(bodyParser.json());
app.use(logger.httpLogger); // registra 1 linha por requisicao concluida

// Demo do seminário (Secret Manager / KMS): /api/security só existe com
// SECURITY_DEMO_ENABLED=true; caso contrário, 404.
mountSecurityDemo(app);

const TodoSchema = new mongoose.Schema({
  text: { type: String, required: true },
  completed: { type: Boolean, default: false },
});
const Todo = mongoose.model("Todo", TodoSchema);

// Helper: cronometra e registra uma operacao de banco.
async function timedDb(operation, req, fn) {
  const start = process.hrtime.bigint();
  try {
    const result = await fn();
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
    logger.dbEvent({ operation, success: true, durationMs, req });
    return result;
  } catch (err) {
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
    logger.dbEvent({
      operation,
      success: false,
      durationMs,
      errorType: err.name || "Error",
      req,
    });
    throw err;
  }
}

app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok" });
});

app.get("/api/todos", async (req, res) => {
  try {
    const todos = await timedDb("find", req, () => Todo.find());
    logger.usageEvent({ event: "todo_listed", req, extra: { count: todos.length } });
    res.json(todos);
  } catch {
    // O detalhe (error_type) já foi registrado por timedDb; o cliente recebe
    // só uma mensagem genérica, nunca err.message.
    res.status(500).json({ message: "Não foi possível carregar as tarefas" });
  }
});

app.post("/api/todos", async (req, res) => {
  const { text } = req.body;
  if (!text) {
    return res.status(400).json({ message: 'O campo "text" é obrigatório' });
  }
  const todo = new Todo({ text, completed: false });
  try {
    const newTodo = await timedDb("save", req, () => todo.save());
    logger.usageEvent({ event: "todo_created", req }); // sem o conteudo da tarefa
    res.status(201).json(newTodo);
  } catch {
    res.status(400).json({ message: "Não foi possível criar a tarefa" });
  }
});

app.patch("/api/todos/:id", async (req, res) => {
  try {
    const todo = await timedDb("findById", req, () => Todo.findById(req.params.id));
    if (!todo) {
      return res.status(404).json({ message: "Tarefa não encontrada" });
    }
    todo.completed = !todo.completed;
    await timedDb("update", req, () => todo.save());
    logger.usageEvent({ event: "todo_completed", req, extra: { completed: todo.completed } });
    res.json(todo);
  } catch {
    res.status(500).json({ message: "Não foi possível atualizar a tarefa" });
  }
});

app.delete("/api/todos/:id", async (req, res) => {
  try {
    const todo = await timedDb("delete", req, () => Todo.findByIdAndDelete(req.params.id));
    if (!todo) {
      return res.status(404).json({ message: "Tarefa não encontrada" });
    }
    logger.usageEvent({ event: "todo_deleted", req });
    res.json({ message: "Tarefa excluída com sucesso" });
  } catch {
    res.status(500).json({ message: "Não foi possível excluir a tarefa" });
  }
});

// Erros que escapam das rotas (ex.: JSON malformado no body). Sem este handler,
// o Express devolve o stack trace ao cliente quando NODE_ENV != production.
app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);
  const status = err.status >= 400 && err.status < 500 ? err.status : 500;
  logger.logEvent(status >= 500 ? "ERROR" : "WARNING", "request_error", "Erro ao processar requisição", {
    error_type: err.name || "Error",
    status_code: status,
  });
  res.status(status).json({
    message: status >= 500 ? "Erro interno do servidor" : "Requisição inválida",
  });
});

app.listen(port, "0.0.0.0", () => {
  logger.logEvent("INFO", "startup", "Servidor rodando na porta " + port);
});
