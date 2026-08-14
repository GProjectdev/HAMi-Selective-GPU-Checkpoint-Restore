#include <cuda_runtime.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

__global__ void fill_kernel(float* data, int n, float seed) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n) {
    data[idx] = seed + static_cast<float>(idx % 1024) * 0.001f;
  }
}

static void check(cudaError_t err, const char* what) {
  if (err != cudaSuccess) {
    std::cerr << what << ": " << cudaGetErrorString(err) << std::endl;
    std::exit(1);
  }
}

int main() {
  const char* workload = std::getenv("WORKLOAD_ID");
  std::string id = workload ? workload : "pod-a";
  const int n = 64 * 1024 * 1024;
  float* device = nullptr;
  check(cudaSetDevice(0), "cudaSetDevice");
  check(cudaMalloc(&device, n * sizeof(float)), "cudaMalloc");

  int iter = 0;
  while (true) {
    fill_kernel<<<(n + 255) / 256, 256>>>(device, n, static_cast<float>(iter));
    check(cudaGetLastError(), "kernel launch");
    check(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    std::cout << id << " heartbeat iteration=" << iter++ << std::endl;
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }
}

