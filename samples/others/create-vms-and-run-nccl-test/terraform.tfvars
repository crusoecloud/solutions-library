# common configuration
location ="us-east1-a"
project_id = ""
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
ssh_private_key_path = "~/.ssh/id_ed25519"
vpc_subnet_id = ""
ib_partition_id = ""

# H100 testing
image_name = "ubuntu24.04-nvidia-sxm-docker"
node_type = "h100-80gb-sxm-ib.8x"
imex_support = false

# H200 testing
#image_name = "ubuntu24.04-nvidia-sxm-docker"
#node_type = "h200-141gb-sxm-ib.8x"
#imex_support = false

# B200 testing
#image_name = "ubuntu24.04-nvidia-sxm-docker-b200"
#node_type = "b200-180gb-sxm-ib.8x"
#imex_support = false

# B300 testing
#image_name = "ubuntu24.04-nvidia-sxm-docker-b300"
#node_type = "b300-288gb-sxm-ib.8x"
#imex_support = false

# GB200 testing
#image_name = "ubuntu24.04-nvidia-nvl-arm64-gb200"
#node_type = "gb200-186gb-nvl-ib.4x"
#imex_support = true

#number of nodes in your test cluster
node_count = 2
#a unique prefix within your project
node_name_prefix = "apple"
