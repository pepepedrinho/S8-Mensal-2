import React, { useState, useEffect } from 'react';
import axios from 'axios';
import './App.css';

function App() {
  const [todos, setTodos] = useState([]);
  const [task, setTask] = useState('');

  // A aplicação é servida pelo mesmo domínio do backend.
  // O Load Balancer decide se /api/* vai para o backend.
  const API_URL = '/api/todos';

  const fetchTodos = async () => {
    try {
      const response = await axios.get(API_URL);
      setTodos(response.data);
    } catch (error) {
      console.error('Erro ao carregar tarefas:', error);
    }
  };

  const addTodo = async () => {
    if (!task.trim()) return;

    try {
      const response = await axios.post(API_URL, { text: task });
      setTodos([...todos, response.data]);
      setTask('');
    } catch (error) {
      console.error('Erro ao adicionar tarefa:', error);
    }
  };

  const toggleComplete = async (id) => {
    try {
      const response = await axios.patch(`${API_URL}/${id}`);
      const updatedTodos = todos.map((todo) =>
        todo._id === id ? response.data : todo
      );
      setTodos(updatedTodos);
    } catch (error) {
      console.error('Erro ao atualizar tarefa:', error);
    }
  };

  const deleteTodo = async (id) => {
    try {
      await axios.delete(`${API_URL}/${id}`);
      setTodos(todos.filter((todo) => todo._id !== id));
    } catch (error) {
      console.error('Erro ao excluir tarefa:', error);
    }
  };

  useEffect(() => {
    fetchTodos();
  }, []);

  return (
    <div className="App">
      <h1>Lista de Tarefas</h1>

      <div>
        <input
          type="text"
          value={task}
          onChange={(e) => setTask(e.target.value)}
          placeholder="Adicione uma tarefa"
        />
        <button onClick={addTodo}>Adicionar</button>
      </div>

      <ul>
        {todos.map((todo) => (
          <li
            key={todo._id}
            style={{
              textDecoration: todo.completed ? 'line-through' : 'none',
            }}
          >
            <span onClick={() => toggleComplete(todo._id)}>
              {todo.text}
            </span>
            <button onClick={() => deleteTodo(todo._id)}>Excluir</button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default App;
