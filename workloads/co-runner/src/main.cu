#include <cuda_runtime.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>

__global__ void spin_kernel(float* data, int n, float value) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n) {
    data[idx] = data[idx] * 1.000001f + value;
  }
}

static void check(cudaError_t err, const char* what) {
  if (err != cudaSuccess) {
    std::cerr << what << ": " << cudaGetErrorString(err) << std::endl;
    std::exit(1);
  }
}

int main() {
  const int n = 64 * 1024 * 1024;
  float* device = nullptr;
  check(cudaSetDevice(0), "cudaSetDevice");
  check(cudaMalloc(&device, n * sizeof(float)), "cudaMalloc");
  check(cudaMemset(device, 0, n * sizeof(float)), "cudaMemset");

  int iter = 0;
  while (true) {
    spin_kernel<<<(n + 255) / 256, 256>>>(device, n, 0.01f);
    check(cudaGetLastError(), "kernel launch");
    check(cudaDeviceSynchronize(), "cudaDeviceSynchronize");
    std::cout << "pod-b heartbeat iteration=" << iter++ << std::endl;
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }
}

