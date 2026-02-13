# common configuration
location ="eu-iceland1-a"
project_id = ""
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
vpc_subnet_id = ""
ib_partition_id = ""

# B200 testing
#image_name = "ubuntu24.04-nvidia-sxm-docker-b200"
#node_type = "b200-180gb-sxm-ib.8x"
#imex_support = false

# GB200 testing
#image_name = "ubuntu24.04-nvidia-nvl-arm64-gb200"
#node_type = "gb200-186gb-nvl-ib.4x"
#imex_support = true

node_count = 2
imex_support = true
node_name_prefix = "apple"
