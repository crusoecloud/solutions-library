import os
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Dataset
from torch.utils.data.distributed import DistributedSampler
import torch.distributed as dist

# ---------------------------------------------------------
# 1. Model Definition
# ---------------------------------------------------------
class SimpleTextModel(nn.Module):
    def __init__(self, vocab_size, d_model, nhead, num_layers, num_classes):
        super().__init__()
        self.embedding = nn.Embedding(vocab_size, d_model)
        # Basic Transformer Encoder
        encoder_layer = nn.TransformerEncoderLayer(d_model=d_model, nhead=nhead, batch_first=True)
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)
        self.fc = nn.Linear(d_model, num_classes)

    def forward(self, x):
        # x shape: [batch_size, seq_len]
        x = self.embedding(x)
        x = self.transformer(x)
        # Pool the sequence by taking the mean across the sequence length
        x = x.mean(dim=1)
        return self.fc(x)

# ---------------------------------------------------------
# 2. Dummy Dataset
# ---------------------------------------------------------
class DummyTextDataset(Dataset):
    def __init__(self, num_samples, seq_len, vocab_size):
        # Generate random integer tokens to simulate text
        self.data = torch.randint(0, vocab_size, (num_samples, seq_len))
        self.labels = torch.randint(0, 2, (num_samples,))

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        return self.data[idx], self.labels[idx]

# ---------------------------------------------------------
# 3. Distributed Setup
# ---------------------------------------------------------
def setup():
    # torchrun sets MASTER_ADDR, MASTER_PORT, RANK, WORLD_SIZE, LOCAL_RANK
    dist.init_process_group(backend="nccl")

    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    return local_rank

def cleanup():
    dist.destroy_process_group()

# ---------------------------------------------------------
# 4. Main Training Loop
# ---------------------------------------------------------
def main():
    local_rank = setup()

    # dist.get_rank() is the global rank across all nodes/GPUs
    global_rank = dist.get_rank()
    world_size = dist.get_world_size()

    if global_rank == 0:
        print(f"World size: {world_size} GPUs across all nodes")

    # Hyperparameters
    vocab_size = 10000
    seq_len = 128
    d_model = 256
    nhead = 8
    num_layers = 4
    num_classes = 2
    batch_size = 64  # Per-GPU batch size; effective batch = batch_size * world_size
    epochs = 30

    dataset = DummyTextDataset(num_samples=16000, seq_len=seq_len, vocab_size=vocab_size)

    # DistributedSampler partitions data across all world_size GPUs
    sampler = DistributedSampler(dataset, num_replicas=world_size, rank=global_rank)
    dataloader = DataLoader(dataset, batch_size=batch_size, sampler=sampler)

    model = SimpleTextModel(vocab_size, d_model, nhead, num_layers, num_classes).cuda(local_rank)
    model = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.AdamW(model.parameters(), lr=1e-4)

    for epoch in range(epochs):
        sampler.set_epoch(epoch)
        model.train()
        total_loss = 0.0

        for batch_idx, (inputs, targets) in enumerate(dataloader):
            inputs = inputs.cuda(local_rank)
            targets = targets.cuda(local_rank)

            optimizer.zero_grad()
            outputs = model(inputs)
            loss = criterion(outputs, targets)
            loss.backward()
            optimizer.step()

            total_loss += loss.item()

        # Log only from the global rank-0 process
        if global_rank == 0:
            avg_loss = total_loss / len(dataloader)
            print(f"Epoch [{epoch+1}/{epochs}] | Average Loss: {avg_loss:.4f}")

    cleanup()

if __name__ == "__main__":
    main()
