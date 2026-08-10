# Derived SGLang image for Kimi K3 on AMD MI355X (gfx950) with fast weight loading.
#
# The stock image serves Kimi K3 correctly, but its default weight loader is unusable on
# network-backed storage, so this image adds two things:
#   1. fastsafetensors  — parallel weight loading (~5 min vs ~2 h for the default
#      "multi-thread" loader, which reads shards ~84 s each over a network filesystem).
#   2. a one-line nogds patch — SGLang's fastsafetensors path calls SafeTensorsFileLoader
#      WITHOUT nogds=True, so on ROCm (no libcufile.so / GPU Direct Storage) it deadlocks
#      trying to open GDS. vLLM forces nogds for TP>1; SGLang does not. (Upstream candidate.)
#
# Base image is pinned per the MI355X optimization work — the 20260802 tag is broken for K3.
FROM lmsysorg/sglang-rocm:rocm720-mi35x-k3-20260727

RUN pip install --no-cache-dir fastsafetensors

RUN sed -i \
      's/loader = SafeTensorsFileLoader(pg, device)/loader = SafeTensorsFileLoader(pg, device, nogds=True)/' \
      /sgl-workspace/sglang/python/sglang/srt/model_loader/weight_utils.py && \
    grep -q 'nogds=True' /sgl-workspace/sglang/python/sglang/srt/model_loader/weight_utils.py

# Build + push to a registry your cluster can pull from, e.g.:
#   docker build -t <registry>/kimi-k3-sglang-fss:20260727 .
#   docker push  <registry>/kimi-k3-sglang-fss:20260727
# then set that image in kimi-k3-sglang.yaml (and create an imagePullSecret if the registry is private).
