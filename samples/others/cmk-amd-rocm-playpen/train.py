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
    # On ROCm, the "nccl" backend automatically points to AMD's RCCL
    dist.init_process_group(backend="nccl")

    # torchrun automatically sets the LOCAL_RANK environment variable
    local_rank = int(os.environ["LOCAL_RANK"])

    # PyTorch maintains the "cuda" naming convention for ROCm GPUs
    torch.cuda.set_device(local_rank)
    return local_rank

def cleanup():
    dist.destroy_process_group()

# ---------------------------------------------------------
# 4. Main Training Loop
# ---------------------------------------------------------
def main():
    local_rank = setup()

    # Hyperparameters
    vocab_size = 10000
    seq_len = 128
    d_model = 256
    nhead = 8
    num_layers = 4
    num_classes = 2
    batch_size = 64 # This is the batch size PER GPU
    epochs = 3

    # Instantiate dataset
    dataset = DummyTextDataset(num_samples=16000, seq_len=seq_len, vocab_size=vocab_size)

    # DistributedSampler ensures each GPU gets a unique subset of the data
    sampler = DistributedSampler(dataset)
    dataloader = DataLoader(dataset, batch_size=batch_size, sampler=sampler)

    # Instantiate the model and map it to the current GPU
    model = SimpleTextModel(vocab_size, d_model, nhead, num_layers, num_classes).cuda(local_rank)

    # Wrap the model in DistributedDataParallel (DDP)
    model = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.AdamW(model.parameters(), lr=1e-4)

    # Training loop
    for epoch in range(epochs):
        # Critical: set the epoch on the sampler to ensure data is shuffled differently each epoch
        sampler.set_epoch(epoch)
        model.train()
        total_loss = 0.0

        for batch_idx, (inputs, targets) in enumerate(dataloader):
            # Move data to the specific GPU
            inputs = inputs.cuda(local_rank)
            targets = targets.cuda(local_rank)

            optimizer.zero_grad()
            outputs = model(inputs)
            loss = criterion(outputs, targets)
            loss.backward()
            optimizer.step()

            total_loss += loss.item()

        # Only print logs from the master process (GPU 0) to avoid spamming the console 8 times
        if local_rank == 0:
            avg_loss = total_loss / len(dataloader)
            print(f"Epoch [{epoch+1}/{epochs}] | Average Loss: {avg_loss:.4f}")

    cleanup()

if __name__ == "__main__":
    main()