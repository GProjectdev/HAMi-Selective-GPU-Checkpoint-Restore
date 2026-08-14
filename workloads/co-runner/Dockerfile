FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
COPY Makefile ./
COPY src ./src
RUN make

ENTRYPOINT ["/workspace/co-runner"]

