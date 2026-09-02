# HAMi Shared GPU 환경에서 GCR+CRIUgpu Checkpoint/Restore가 가능한 이유

## 1. 결론

HAMi Shared GPU 환경에서 checkpoint/restore가 가능한 이유는 HAMi가 물리 GPU를 완전히 다른 하드웨어 장치로 쪼개는 방식이 아니라, 하나의 물리 GPU를 여러 Pod가 함께 사용하도록 스케줄링하고 CUDA 호출 경로를 제어하는 방식으로 vGPU를 제공하기 때문이다.

즉, 이 실험에서 checkpoint/restore가 된 이유는 다음과 같이 역할이 분리되어 있기 때문이다.

```text
HAMi:
  Pod별 GPU 사용량을 제한하고, 어떤 Pod가 어떤 GPU를 쓰는지 관리한다.

GCR:
  대상 Pod 프로세스의 CUDA memory allocation을 추적하고,
  checkpoint 시 해당 프로세스가 소유한 GPU data buffer를 host로 복사해 external blob으로 저장한다.

CRIUgpu/CRIU:
  CUDA control state와 CPU process state를 checkpoint한다.

patched CRI-O restore path:
  checkpoint archive, GPU blob, HAMi runtime/cache를 다시 연결하여 Pod를 복원한다.
```

따라서 “HAMi라서 checkpoint가 된다”라기보다는, 더 정확히는 다음과 같다.

```text
HAMi Shared GPU 방식은 GCR+CRIUgpu가 대상 Pod의 CUDA context와 GPU allocation을 추적할 수 있는 형태로 동작한다.
그래서 Pod 단위 selective checkpoint/restore를 적용할 수 있었다.
```

## 2. HAMi는 실제 GPU를 어떻게 공유시키는가

HAMi는 MIG처럼 물리 GPU를 하드웨어 partition으로 나누는 방식과 다르다. HAMi는 Kubernetes scheduler/device-plugin, container runtime hook, 사용자 공간 라이브러리 기반 제어를 조합하여 Pod에 vGPU처럼 보이는 실행 환경을 제공한다.

실험 Pod에는 다음과 같은 리소스 요청이 들어간다.

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 8192
    nvidia.com/gpucores: 30
```

여기서 `nvidia.com/gpumem`과 `nvidia.com/gpucores`는 물리 GPU 메모리와 GPU compute 사용량을 Pod별로 제한하기 위한 HAMi 리소스이다.

HAMi scheduler는 node annotation에 기록된 GPU 정보와 남은 vGPU 용량을 보고 Pod를 배치한다. 이후 HAMi device-plugin/runtime hook은 컨테이너 안에 다음과 같은 HAMi runtime 구성을 주입한다.

```text
/usr/local/vgpu
/usr/local/vgpu/libvgpu.so
/usr/local/vgpu/containers/<pod-uid>_<container-name>/*.cache
/tmp/vgpulock
/etc/ld.so.preload
```

이 구조 때문에 컨테이너 안의 CUDA workload는 동일 물리 GPU를 사용하지만, HAMi의 vGPU runtime을 통해 Pod별 사용량 제한과 accounting을 받는다.

## 3. 왜 Shared GPU에서도 Pod A만 Checkpoint할 수 있는가

GPU checkpoint가 물리 GPU 전체를 저장하는 방식이라면 Pod A만 checkpoint하는 것은 어렵다. 하지만 GCR+CRIUgpu 방식은 물리 GPU 전체를 덤프하는 방식이 아니라, checkpoint 대상 프로세스의 CUDA 상태와 GPU data buffer를 대상으로 한다.

실험에서 중요한 단위는 다음과 같다.

```text
checkpoint 대상 = Kubernetes Pod 전체가 아니라,
                 Pod 안의 특정 container/process와 그 프로세스가 소유한 CUDA allocation
```

GCR interceptor는 대상 CUDA workload의 실행 시점에 `LD_PRELOAD`로 로드된다. 이 interceptor는 대상 프로세스의 CUDA memory allocation과 관련된 정보를 추적한다. checkpoint signal을 받으면 GCR은 그 프로세스가 관리하는 GPU data buffer를 host로 복사하여 `.blob`으로 저장한다.

실제 성공 로그는 다음과 같은 형태였다.

```text
[gcr] checkpoint signal received
[gcr][engine] freeze: 1 segs, 268435456 bytes -> external blob
[gcr] checkpoint ACK sent
```

Inference workload에서는 다음과 같이 더 많은 segment가 관찰되었다.

```text
[gcr][engine] freeze: 19 segs, 304087040 bytes -> external blob
```

이 값은 물리 GPU 전체 메모리가 아니라, 해당 checkpoint 대상 프로세스에서 GCR이 추적한 GPU data buffer 크기이다. 따라서 같은 GPU 위에 Pod B가 있어도 Pod B 프로세스의 CUDA allocation이 Pod A의 GCR interceptor 추적 대상에 포함되지 않으면 Pod A checkpoint blob에 들어가지 않는다.

정리하면 다음과 같다.

```text
Pod A checkpoint:
  Pod A 프로세스의 CUDA allocation과 process state를 저장한다.

Pod B:
  같은 물리 GPU를 공유하지만 별도 프로세스/컨테이너이므로 Pod A checkpoint 대상이 아니다.
```

이것이 “shared GPU이지만 selective checkpoint가 가능한” 핵심 이유이다.

## 4. Pod B 데이터가 섞이지 않는 이유

물리 GPU 메모리 관점에서는 Pod A와 Pod B가 같은 GPU DRAM을 공유한다. 그래서 직관적으로는 “Pod A checkpoint 중 Pod B 메모리까지 저장되는 것 아닌가?”라는 의문이 생긴다.

하지만 CUDA 애플리케이션은 임의의 물리 GPU DRAM 주소를 직접 덤프하지 않는다. 사용자 프로세스는 CUDA runtime/driver API를 통해 자신에게 할당된 device pointer와 CUDA context를 사용한다. GCR이 추적하는 것도 이 프로세스의 CUDA allocation 단위이다.

따라서 GCR 관점의 checkpoint 대상은 다음과 같다.

```text
물리 GPU 전체 메모리:
  checkpoint 대상 아님

대상 프로세스의 CUDA allocation:
  checkpoint 대상

다른 Pod의 CUDA allocation:
  대상 프로세스 주소 공간과 allocation table에 속하지 않으므로 checkpoint 대상 아님
```

이는 CPU process checkpoint와 유사하게 볼 수 있다. CRIU가 host의 전체 RAM을 저장하는 것이 아니라 특정 process tree의 주소 공간, 파일 descriptor, namespace 상태를 저장하는 것처럼, GCR+CRIUgpu도 대상 CUDA process의 GPU 상태와 GPU data buffer를 저장한다.

다만 주의할 점은 있다. HAMi Shared GPU는 하드웨어 isolation이 아니라 software/runtime 기반 isolation에 가깝다. 따라서 checkpoint의 정확성은 다음 조건에 의존한다.

- GCR interceptor가 대상 workload의 CUDA allocation을 정확히 추적해야 한다.
- workload가 GCR이 지원하는 CUDA memory path를 사용해야 한다.
- CUDA IPC, NCCL, UVM, MPS, MIG 등 복잡한 GPU 공유/통신 경로는 별도 검증이 필요하다.
- Pod 전체 init 과정이 아니라 실제 CUDA workload 실행 시점에 GCR `LD_PRELOAD`를 적용해야 한다.

이번 실험은 단일 CUDA process 기반 workload에서 이 조건이 만족된 경우를 검증한 것이다.

## 5. 왜 MIG와는 다른가

MIG는 GPU를 하드웨어 수준의 GPU instance와 compute instance로 나눈다. 애플리케이션 입장에서는 일반 GPU와 다른 MIG device를 사용하게 되고, device identity, memory partition, driver-visible topology가 달라진다.

반면 HAMi shared GPU는 같은 물리 GPU를 runtime/scheduler/device-plugin 계층에서 나누어 쓰게 한다. 그래서 대상 Pod의 CUDA process는 일반 CUDA context와 device memory allocation을 만들고, GCR interceptor는 그 프로세스의 CUDA allocation을 추적할 수 있다.

즉 차이는 다음과 같이 볼 수 있다.

```text
HAMi shared GPU:
  같은 물리 GPU 위에서 Pod별 사용량을 software/runtime 계층에서 제한
  -> GCR이 대상 process의 CUDA allocation을 추적하기 쉬움

MIG:
  GPU가 hardware partition device로 노출
  -> device identity/control state/driver 경로가 달라져 별도 지원 필요
```

따라서 “GPU sharing이면 모두 checkpoint 가능하다”가 아니라, 이번 결과는 “HAMi 방식의 shared GPU에서는 GCR+CRIUgpu 경로가 성립했다”로 표현하는 것이 정확하다.

## 6. Restore가 가능했던 이유

Restore가 가능하려면 checkpoint 때 저장한 CPU/process state와 GPU data buffer를 다시 같은 실행 구조로 연결해야 한다.

이번 실험에서 restore는 다음 순서로 성립했다.

```text
1. checkpoint archive `.tar` 확보
2. GPU memory external blob `.blob` 확보
3. 원본 Pod UID와 container name 기반 metadata 확보
4. HAMi runtime/cache 파일 확보
5. Restore Pod 생성
6. patched CRI-O가 restore annotation을 감지
7. CRIU/CRIUgpu restore 수행
8. GCR이 `.blob`에서 GPU data buffer를 같은 VA로 remap + H2D 복원
9. CUDA workload gate 해제
10. workload heartbeat 재개
```

성공 로그는 다음과 같았다.

```text
[gcr] restore signal received
[gcr][engine] remap: 1 segs restored from external blob to same VA + H2D; 0 failed
[gcr] gate: released, launch proceeds
[gcr] restore ACK sent
pod-a heartbeat iteration=48
```

여기서 중요한 부분은 `same VA + H2D`와 `0 failed`이다.

```text
same VA:
  checkpoint 당시 CUDA workload가 사용하던 가상 주소와 호환되는 형태로 다시 매핑했다는 의미

H2D:
  host에 저장해 둔 GPU data blob을 device memory로 다시 복사했다는 의미

0 failed:
  GCR이 복원하려던 GPU data segment remap이 실패하지 않았다는 의미
```

즉 restore가 된 이유는 단순히 Pod가 새로 Running이 되었기 때문이 아니라, checkpoint 당시 분리 저장한 GPU data buffer가 restore 시점에 CUDA workload가 다시 사용할 수 있는 형태로 복원되었기 때문이다.

## 7. HAMi 환경에서 Restore를 위해 추가 보정이 필요했던 이유

HAMi는 컨테이너에 vGPU runtime 파일과 cache를 주입한다. 이 경로들은 checkpoint 시점에 CRIU image의 mount/file 정보에 남는다.

대표 경로는 다음과 같다.

```text
/usr/local/vgpu
/usr/local/vgpu/libvgpu.so
/usr/local/vgpu/containers/<pod-uid>_<container-name>/*.cache
/tmp/vgpulock
/etc/ld.so.preload
```

Restore 시점에 이 파일과 mountpoint가 없거나 permission이 checkpoint 당시와 다르면 CRIU가 mount 또는 file restore 단계에서 실패할 수 있다.

그래서 다음 보정이 필요했다.

| 필요한 보정 | 이유 | 처리 |
|---|---|---|
| HAMi runtime mount 보존 | CRIU image에 HAMi bind mount 정보가 남기 때문 | restore 전에 `/usr/local/vgpu`, `libvgpu.so` mount source를 준비 |
| HAMi cache 복구 | restore Pod는 원본 Pod의 `/usr/local/vgpu/containers/.../*.cache`를 그대로 갖고 있지 않음 | source cache를 restore-cache로 복사 |
| cache mode 보존 | CRIU가 checkpoint 당시 파일 mode를 엄격히 비교 | `.cache` 파일을 `0666`으로 맞춤 |
| GCR `LD_PRELOAD` 범위 제한 | 컨테이너 init 전체를 가로채면 HAMi 초기화와 충돌 가능 | 실제 CUDA workload 실행 시점에만 interceptor 적용 |
| stale kubelet mount 제거 | 원본 Pod UID에 묶인 임시 mount가 restore 환경에 없을 수 있음 | CRIU restore config에서 transient mount 제거 또는 external mount 보정 |

이 보정들은 checkpoint 가능성 자체보다 restore 재현성을 위해 중요했다. 즉 HAMi shared GPU에서 GPU data를 저장하는 것은 GCR이 담당하지만, 그 결과를 다시 Pod로 복원하려면 HAMi runtime 환경도 checkpoint 당시와 호환되게 맞춰야 한다.

## 8. 이번 실험으로 확인된 것

이번 실험에서 확인한 사실은 다음과 같다.

```text
1. HAMi shared GPU 환경에서 여러 Pod가 같은 물리 GPU를 공유할 수 있다.
2. GCR interceptor가 대상 Pod의 CUDA GPU data buffer를 selective하게 checkpoint할 수 있다.
3. Pod A checkpoint 중 Pod B는 Running 상태와 heartbeat를 유지했다.
4. checkpoint 결과로 `.tar`와 `.blob` artifact가 생성되었다.
5. patched CRI-O + CRIUgpu + GCR restore path를 통해 Pod A가 복원되었다.
6. restore 후 GCR remap/H2D가 `0 failed`로 완료되었고 CUDA workload가 재개되었다.
```

따라서 교수님께 보여줄 수 있는 결론은 다음과 같다.

```text
HAMi는 GPU를 하드웨어 partition으로 분리하지 않고, 동일 물리 GPU를 Pod별 vGPU runtime으로 공유시킨다.
GCR+CRIUgpu는 물리 GPU 전체가 아니라 checkpoint 대상 CUDA process의 allocation과 state를 저장한다.
따라서 HAMi shared GPU 환경에서도 Pod 단위 selective GPU checkpoint가 가능했고,
HAMi runtime/cache와 GPU blob을 restore 시점에 다시 맞추면 Pod 복원도 가능했다.
```

## 9. 한계와 주의할 표현

다음 표현은 피하는 것이 좋다.

```text
HAMi가 GPU checkpoint 기능을 제공한다.
```

더 정확한 표현은 다음과 같다.

```text
HAMi는 shared GPU 실행 환경을 제공하고,
GCR+CRIUgpu가 해당 환경 위에서 대상 CUDA workload의 checkpoint/restore를 수행한다.
```

또한 다음도 단정하면 안 된다.

```text
모든 GPU sharing 방식에서 checkpoint/restore가 가능하다.
```

이번 실험의 정확한 범위는 다음과 같다.

```text
HAMi shared GPU 환경의 단일 CUDA process workload에서,
GCR selective interception과 CRIUgpu checkpoint/restore 경로가 동작함을 검증했다.
```

MIG, MPS, NCCL, CUDA IPC, UVM, multi-process distributed inference/training은 별도 검증 대상이다.
