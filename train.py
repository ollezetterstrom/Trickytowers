import socket
import torch
import torch.nn as nn
import torch.optim as optim
import random
import os
import sys

# === CONFIGURATION ===
HOST = '127.0.0.1'
PORT = 5005
INPUT_SIZE = 25
OUTPUT_SIZE = 5

BATCH_SIZE = 512
GAMMA = 0.99
EPSILON_START = 1.0
EPSILON_END = 0.05
EPSILON_DECAY = 0.9999 
TARGET_UPDATE = 1000
MEMORY_SIZE = 100000
LR = 0.0001

device = torch.device("cpu")

class DuelingDQN(nn.Module):
    def __init__(self):
        super(DuelingDQN, self).__init__()
        self.feature_layer = nn.Sequential(
            nn.Linear(INPUT_SIZE, 256), nn.ReLU(),
            nn.Linear(256, 256), nn.ReLU()
        )
        self.value_stream = nn.Sequential(nn.Linear(256, 128), nn.ReLU(), nn.Linear(128, 1))
        self.advantage_stream = nn.Sequential(nn.Linear(256, 128), nn.ReLU(), nn.Linear(128, OUTPUT_SIZE))
    def forward(self, x):
        features = self.feature_layer(x)
        values = self.value_stream(features)
        advantages = self.advantage_stream(features)
        return values + (advantages - advantages.mean())

class FastReplayBuffer:
    def __init__(self, capacity, input_size):
        self.capacity = capacity
        self.ptr = 0; self.size = 0
        self.states = torch.zeros((capacity, input_size), dtype=torch.float32, device=device)
        self.actions = torch.zeros((capacity, 1), dtype=torch.long, device=device)
        self.rewards = torch.zeros((capacity, 1), dtype=torch.float32, device=device)
        self.next_states = torch.zeros((capacity, input_size), dtype=torch.float32, device=device)
        self.dones = torch.zeros((capacity, 1), dtype=torch.float32, device=device)
    def push(self, state, action, reward, next_state, done):
        self.states[self.ptr] = state; self.actions[self.ptr] = action; self.rewards[self.ptr] = reward
        self.next_states[self.ptr] = next_state; self.dones[self.ptr] = done
        self.ptr = (self.ptr + 1) % self.capacity; self.size = min(self.size + 1, self.capacity)
    def sample(self, batch_size):
        indices = torch.randint(0, self.size, (batch_size,), device=device)
        return (self.states[indices], self.actions[indices], self.rewards[indices], self.next_states[indices], self.dones[indices])
    def __len__(self): return self.size

def train():
    policy_net = DuelingDQN().to(device)
    target_net = DuelingDQN().to(device)
    target_net.load_state_dict(policy_net.state_dict()); target_net.eval()
    if os.path.exists("tricky_towers_ai.pth"):
        try: policy_net.load_state_dict(torch.load("tricky_towers_ai.pth")); target_net.load_state_dict(policy_net.state_dict()); print("🧠 Loaded brain!")
        except: pass
    optimizer = optim.Adam(policy_net.parameters(), lr=LR)
    memory = FastReplayBuffer(MEMORY_SIZE, INPUT_SIZE)
    
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    server.bind((HOST, PORT)); server.listen(1)
    print("⏳ Waiting for Love2D..."); conn, addr = server.accept(); print("✅ Connected!")
    
    steps_done = 0; epsilon = EPSILON_START; conn.send(b"RESET\n")
    current_state = torch.zeros(INPUT_SIZE, device=device)
    last_state = None; last_action = 0
    episode_rewards = []; current_episode_reward = 0; episode_count = 0
    death_reason = ""

    try:
        while True:
            data = conn.recv(4096).decode('utf-8').strip()
            if not data: break
            messages = data.split('\n'); 
            if not messages[-1]: messages.pop()
            
            for msg in messages:
                try:
                    parts = msg.split('|')
                    vals = [float(x) for x in parts[0].split(',')]
                    reward = float(parts[1])
                    done = int(parts[2])
                    if len(parts) > 3: death_reason = parts[3] # Read Reason
                    current_state = torch.tensor(vals, dtype=torch.float32, device=device)
                except: continue

                current_episode_reward += reward
                if last_state is not None: memory.push(last_state, last_action, reward, current_state, done)
                
                if len(memory) > BATCH_SIZE:
                    states, actions, rewards, next_states, dones = memory.sample(BATCH_SIZE)
                    q_values = policy_net(states).gather(1, actions)
                    next_actions = policy_net(next_states).argmax(1).unsqueeze(1)
                    next_q_values = target_net(next_states).gather(1, next_actions)
                    expected_q_values = rewards + (GAMMA * next_q_values * (1 - dones))
                    loss = nn.MSELoss()(q_values, expected_q_values)
                    optimizer.zero_grad(); loss.backward(); optimizer.step()

                if random.random() < epsilon: action = random.randint(0, OUTPUT_SIZE - 1)
                else:
                    with torch.no_grad(): action = torch.argmax(policy_net(current_state.unsqueeze(0))).item()

                if epsilon > EPSILON_END: epsilon *= EPSILON_DECAY
                if steps_done % TARGET_UPDATE == 0: target_net.load_state_dict(policy_net.state_dict())
                steps_done += 1

                if done:
                    last_state = None; episode_count += 1
                    episode_rewards.append(current_episode_reward)
                    avg = sum(episode_rewards[-50:]) / min(len(episode_rewards), 50)
                    
                    # Print reason for death
                    print(f"Ep: {episode_count} | R: {current_episode_reward:.1f} | Avg: {avg:.1f} | Cause: {death_reason}")
                    
                    current_episode_reward = 0; conn.send(b"RESET\n")
                    if episode_count % 50 == 0: torch.save(policy_net.state_dict(), "tricky_towers_ai.pth")
                else:
                    last_state = current_state; last_action = action; conn.send(f"{action}\n".encode('utf-8'))
    finally:
        print("💾 Saving..."); torch.save(policy_net.state_dict(), "tricky_towers_ai.pth"); conn.close(); server.close()

if __name__ == "__main__": train()