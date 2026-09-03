const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const bodyParser = require('body-parser');

const app = express();
const port = process.env.PORT || 5000;

// Produção (Cloud Run + Firestore MongoDB compatibility):
// MONGO_URI pode ser informada diretamente pelo ambiente.
// Como alternativa, construímos a URI a partir dos dados do banco.
//
// Desenvolvimento local:
// usamos o MongoDB do docker-compose como fallback.
const mongoUri =
  process.env.MONGO_URI ||
  (process.env.FIRESTORE_DB_UID &&
    process.env.FIRESTORE_DB_LOCATION &&
    process.env.FIRESTORE_DB_ID
    ? `mongodb://${process.env.FIRESTORE_DB_UID}.${process.env.FIRESTORE_DB_LOCATION}.firestore.goog:443/${process.env.FIRESTORE_DB_ID}?loadBalanced=true&tls=true&retryWrites=false&authMechanism=MONGODB-OIDC&authMechanismProperties=ENVIRONMENT:gcp,TOKEN_RESOURCE:FIRESTORE`
    : 'mongodb://root:rootpassword@mongo-todo:27017/todo-app?authSource=admin');

mongoose
  .connect(mongoUri)
  .then(() => console.log('Conectado ao banco de dados'))
  .catch((err) => {
    console.error('Erro ao conectar ao banco de dados:', err);
    process.exit(1);
  });

app.use(cors());
app.use(bodyParser.json());

const TodoSchema = new mongoose.Schema({
  text: { type: String, required: true },
  completed: { type: Boolean, default: false },
});

const Todo = mongoose.model('Todo', TodoSchema);

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/api/todos', async (req, res) => {
  try {
    const todos = await Todo.find();
    res.json(todos);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

app.post('/api/todos', async (req, res) => {
  const { text } = req.body;

  if (!text) {
    return res.status(400).json({
      message: 'O campo "text" é obrigatório',
    });
  }

  const todo = new Todo({
    text,
    completed: false,
  });

  try {
    const newTodo = await todo.save();
    res.status(201).json(newTodo);
  } catch (err) {
    res.status(400).json({ message: err.message });
  }
});

app.patch('/api/todos/:id', async (req, res) => {
  try {
    const todo = await Todo.findById(req.params.id);

    if (!todo) {
      return res.status(404).json({ message: 'Tarefa não encontrada' });
    }

    todo.completed = !todo.completed;
    await todo.save();
    res.json(todo);
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

app.delete('/api/todos/:id', async (req, res) => {
  try {
    const todo = await Todo.findByIdAndDelete(req.params.id);

    if (!todo) {
      return res.status(404).json({ message: 'Tarefa não encontrada' });
    }

    res.json({ message: 'Tarefa excluída com sucesso' });
  } catch (err) {
    res.status(500).json({ message: err.message });
  }
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Servidor rodando na porta ${port}`);
});
