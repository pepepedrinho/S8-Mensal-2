const express = require("express");
const mongoose = require("mongoose");
const cors = require("cors");
const bodyParser = require("body-parser");
const logger = require("./logger");

const app = express();
const port = process.env.PORT || 5000;

const mongoUri =
  process.env.MONGO_URI ||
  (process.env.FIRESTORE_DB_UID &&
  process.env.FIRESTORE_DB_LOCATION &&
  process.env.FIRESTORE_DB_ID
    ? `mongodb://${process.env.FIRESTORE_DB_UID}.${process.env.FIRESTORE_DB_LOCATION}.firestore.goog:443/${process.env.FIRESTORE_DB_ID}?loadBalanced=true&tls=true&retryWrites=false&authMechanism=MONGODB-OIDC&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE`
    : "mongodb://root:rootpassword@mongo-todo:27017/todo-app?authSource=admin");

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
  } catch (err) {
    res.status(500).json({ message: err.message });
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
  } catch (err) {
    res.status(400).json({ message: err.message });
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
  } catch (err) {
    res.status(500).json({ message: err.message });
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
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

app.listen(port, "0.0.0.0", () => {
  logger.logEvent("INFO", "startup", "Servidor rodando na porta " + port);
});
