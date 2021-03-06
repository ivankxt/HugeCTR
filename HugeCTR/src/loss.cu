/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#include <vector>
#include "HugeCTR/include/loss.hpp"
#include "HugeCTR/include/utils.cuh"

namespace HugeCTR {

CrossEntropyLoss::CrossEntropyLoss(Tensor<float> &label_tensors, Tensor<float> &input_tensors,
                                   Tensor<float> &loss_tensors, int device_id)
    : Loss(device_id) {
  input_tensors_.push_back(std::ref(input_tensors));
  label_tensors_.push_back(std::ref(label_tensors));
  loss_tensors_.push_back(std::ref(loss_tensors));
}

// Suppose we use one thread to calculate one sample
__global__ void CrossEntropy_Kernel(float *input, float *label, float *cel_loss, int batch_size,
                                    int feature_dim, bool row_major, int scaler) {
  int tid = threadIdx.x;
  extern __shared__ float loss_s[];

  loss_s[tid] = 0.0f;

  float z0_exp, z1_exp, a0, a1;
  int id1, id2;

  for (int i = tid; i < batch_size; i += blockDim.x) {
    id1 = row_major ? i * feature_dim : i;
    id2 = row_major ? i * feature_dim + 1 : i + batch_size;
    z0_exp = exp((double)input[id1]);
    z1_exp = exp((double)input[id2]);

    a0 = z0_exp / (z0_exp + z1_exp);
    a1 = z1_exp / (z0_exp + z1_exp);

    bool no_click = label[i] < 0.5f;

    // calculate the grad
    input[id1] = (a0 - (no_click ? 1.0f : 0.0f)) / batch_size * scaler;
    input[id2] = (a1 - (!no_click ? 1.0f : 0.0f)) / batch_size * scaler;
    ;

    loss_s[tid] += -1 * log(no_click ? a0 : a1);
  }
  __syncthreads();

  float loss_tmp = 0.0f;

  if (tid == 0) {
    for (int i = 0; i < blockDim.x; ++i) loss_tmp += loss_s[i];
    cel_loss[0] = loss_tmp / batch_size;
  }
}

void CrossEntropyLoss::fused_loss_computation(cudaStream_t stream) {
  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(get_device_id(), &o_device));

  Tensor<float> input_tensor = input_tensors_[0];
  Tensor<float> label_tensor = label_tensors_[0];
  Tensor<float> loss_tensor = loss_tensors_[0];

  if (input_tensor.get_format() != label_tensor.get_format())
    CK_THROW_(Error_t::WrongInput, "Format of input tensor and label tensor don't match");

  bool row_major = (input_tensor.get_format() == TensorFormat_t::HW);

  std::vector<int> input_dim = input_tensor.get_dims();
  std::vector<int> label_dim = label_tensor.get_dims();

  int batch_size = row_major ? input_dim[0] : input_dim[1];
  int feature_dim = row_major ? input_dim[1] : input_dim[0];

  if (feature_dim != 2)
    CK_THROW_(Error_t::WrongInput, "The feature dimension of CE loss input should be 2");
  if (row_major && input_dim[0] != label_dim[0])
    CK_THROW_(Error_t::WrongInput, "The batch sizes of input tensor and label tensor are not same");
  if (!row_major && input_dim[1] != label_dim[1])
    CK_THROW_(Error_t::WrongInput, "The batch sizes of input tensor and label tensor are not same");

  float *input = input_tensor.get_ptr();
  float *label = label_tensor.get_ptr();
  float *cel_loss = loss_tensor.get_ptr();

  int block_size = min(batch_size, 1024);

  int scaler = 1;
#ifdef SCALE_128
  scaler = 128;
#elif SCALE_256
  scaler = 256;
#elif SCALE_512
  scaler = 512;
#elif SCALE_1024
  scaler = 1024;
#else
  scaler = 1;
#endif
  //    printf("Cross Entropy scaler %d\n", scaler);

  CrossEntropy_Kernel<<<1, block_size, block_size * sizeof(float), stream>>>(
      input, label, cel_loss, batch_size, feature_dim, row_major, scaler);

#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif

  CK_CUDA_THROW_(get_set_device(o_device));
}

BinaryCrossEntropyLoss::BinaryCrossEntropyLoss(Tensor<float> &label_tensors,
                                               Tensor<float> &input_tensors,
                                               Tensor<float> &loss_tensors, int device_id)
    : Loss(device_id) {
  input_tensors_.push_back(std::ref(input_tensors));
  label_tensors_.push_back(std::ref(label_tensors));
  loss_tensors_.push_back(std::ref(loss_tensors));
}
// Suppose we use one thread to calculate one sample
__global__ void BinaryCrossEntropy_Kernel(float *input, float *label, float *bce_loss, int scaler,
                                          int batch_size) {
  const float MIN_ = 1e-6;
  const float MIN_X = -707.f;
  int tid = threadIdx.x;
  extern __shared__ float loss_s[];
  loss_s[tid] = 0.0f;

  float x, y;
  double val;

  for (int i = tid; i < batch_size; i += blockDim.x) {
    x = input[i] < MIN_X ? MIN_X : input[i];
    double exp_neg_x = exp((double)-x);
    val = 1.0f / (1.0f + exp_neg_x);
    y = label[i];

    loss_s[tid] += y * log(val + MIN_) + (1.0f - y) * log(1.0f - val + MIN_);

    // grad
    input[i] = -1.0f * val * (y - val) * exp_neg_x / (1.0f - val + MIN_) / batch_size * scaler;
  }
  __syncthreads();

  float loss_tmp = 0.0f;
  if (tid == 0) {
    for (int i = 0; i < blockDim.x; ++i) loss_tmp += loss_s[i];
    bce_loss[0] = -loss_tmp / batch_size;
  }
}

void BinaryCrossEntropyLoss::fused_loss_computation(cudaStream_t stream) {
  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(get_device_id(), &o_device));

  Tensor<float> input_tensor = input_tensors_[0];
  Tensor<float> label_tensor = label_tensors_[0];
  Tensor<float> loss_tensor = loss_tensors_[0];

  if (input_tensor.get_format() != label_tensor.get_format())
    CK_THROW_(Error_t::WrongInput, "Format of input tensor and label tensor don't match");

  bool row_major = (input_tensor.get_format() == TensorFormat_t::HW);

  std::vector<int> input_dim = input_tensor.get_dims();
  std::vector<int> label_dim = label_tensor.get_dims();

  int batch_size = row_major ? input_dim[0] : input_dim[1];
  int feature_dim = row_major ? input_dim[1] : input_dim[0];

  if (feature_dim != 1)
    CK_THROW_(Error_t::WrongInput, "The feature dimension of BCE loss input should be 1");

  float *input = input_tensor.get_ptr();
  float *label = label_tensor.get_ptr();
  float *bce_loss = loss_tensor.get_ptr();

  int block_size = min(batch_size, 1024);

  int scaler = 1;
#ifdef SCALE_128
  scaler = 128;
#elif SCALE_256
  scaler = 256;
#elif SCALE_512
  scaler = 512;
#elif SCALE_1024
  scaler = 1024;
#else
  scaler = 1;
#endif
  //   printf("scaler %d\n", scaler);

  BinaryCrossEntropy_Kernel<<<1, block_size, block_size * sizeof(float), stream>>>(
      input, label, bce_loss, scaler, batch_size);

#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif

  CK_CUDA_THROW_(get_set_device(o_device));
}

__forceinline__ __device__ __host__ float cross_entropy_loss(float x, float y) {
  const float MIN_ = 1e-6;
  const float MIN_X = -707.f;
  const double exp_neg_x = x < MIN_X ? exp((double)-MIN_X) : exp((double)-x);
  const double val = 1.0f / (1.0f + exp_neg_x);
  float loss = y * log(val + MIN_) + (1.0f - y) * log(1.0f - val + MIN_);
  return loss;
}

__forceinline__ __device__ __host__ float cross_entropy_loss_backward(float x, float y) {
  const float MIN_ = 1e-6;
  const float MIN_X = -707.f;
  const double exp_neg_x = x < MIN_X ? exp((double)-MIN_X) : exp((double)-x);
  const double val = 1.0f / (1.0f + exp_neg_x);
  float grad = -1.0f * val * (y - val) * exp_neg_x / (1.0f - val + MIN_);
  return grad;
}

__global__ void MultiCrossEntropy_Kernel(float *input, const float *label,
                                         const float *target_weight, float *bce_loss, int batchsize,
                                         int labels_per_sample, int scaler) {
  int tid = threadIdx.x + blockDim.x * blockIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  float loss_s = 0.f;
  const int size = batchsize * labels_per_sample;
  for (int i = tid; i < size; i += num_threads) {
    int target_weight_idx = i % labels_per_sample;
    const float x = input[i];
    const float y = label[i];
    float loss =
        (label[i] < -0.5) ? 0.f : (target_weight[target_weight_idx] * cross_entropy_loss(x, y));
    loss_s += loss;
    input[i] = (label[i] < -0.5) ? 0.f
                                 : (target_weight[target_weight_idx] *
                                    cross_entropy_loss_backward(x, y) / size * scaler);
    // if(i == 0){
    //   printf("i=%d, x=%f, y=%f, target_weight[target_weight_idx]=%f, loss=%f, input=%f\n", i, x,
    //   y, target_weight[target_weight_idx], loss, input[i]);
    // }
  }

  atomic_global_sum_div(-loss_s, bce_loss, size);
  return;
}

void MultiCrossEntropyLoss::fused_loss_computation(cudaStream_t stream) {
  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(get_device_id(), &o_device));

  float *input = input_tensors_[0].get().get_ptr();
  const float *label = label_tensors_[0].get().get_ptr();
  float *loss = loss_tensors_[0].get().get_ptr();
  float *target_weight = target_weight_->get_ptr();
  int batchsize = input_tensors_[0].get().get_dims()[0];
  int labels_per_sample = input_tensors_[0].get().get_dims()[1];
  const int BLOCK_SIZE = 256;
  const int GRID_SIZE = min(40, (batchsize * labels_per_sample - 1) / BLOCK_SIZE);
  cudaMemsetAsync(loss, 0, loss_tensors_[0].get().get_size(), stream);

  int scaler = 1;
#ifdef SCALE_128
  scaler = 128;
#elif SCALE_256
  scaler = 256;
#elif SCALE_512
  scaler = 512;
#elif SCALE_1024
  scaler = 1024;
#else
  scaler = 1;
#endif
  //  printf("MultiCrossEntropy scaler %d\n", scaler);
  MultiCrossEntropy_Kernel<<<GRID_SIZE, BLOCK_SIZE, 0, stream>>>(
      input, label, target_weight, loss, batchsize, labels_per_sample, scaler);

#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif

  CK_CUDA_THROW_(get_set_device(o_device));

  return;
}

MultiCrossEntropyLoss::MultiCrossEntropyLoss(Tensor<float> &label_tensor,
                                             Tensor<float> &input_tensor,
                                             Tensor<float> &loss_tensor,
                                             const std::vector<float> target_weight, int device_id)
    : Loss(device_id) {
  if (label_tensor.get_dims().size() != 2 || label_tensor.get_format() != TensorFormat_t::HW ||
      input_tensor.get_dims().size() != 2 || input_tensor.get_format() != TensorFormat_t::HW ||
      label_tensor.get_dims()[0] != input_tensor.get_dims()[0] ||
      label_tensor.get_dims()[1] != input_tensor.get_dims()[1]) {
    CK_THROW_(Error_t::WrongInput, "Format of input tensor and label tensor don't match");
  }
  // verify the length of target_weight
  if ((int)target_weight.size() != input_tensor.get_dims()[1]) {
    CK_THROW_(Error_t::WrongInput, "target_weight.size() != input_tensor.get_dims()[0]");
  }
  input_tensors_.push_back(std::ref(input_tensor));
  label_tensors_.push_back(std::ref(label_tensor));
  loss_tensors_.push_back(std::ref(loss_tensor));

  // load target_weight to internal Tensor
  internal_buff_ = new GeneralBuffer<float>();
  std::vector<int> twdim = {1, label_tensor.get_dims()[1]};
  target_weight_ = new Tensor<float>(twdim, *internal_buff_, TensorFormat_t::HW);
  internal_buff_->init(device_id);
  int o_device = -1;
  CK_CUDA_THROW_(get_set_device(device_id, &o_device));
  CK_CUDA_THROW_(cudaMemcpy(target_weight_->get_ptr(), target_weight.data(),
                            target_weight_->get_size(), cudaMemcpyHostToDevice));
  CK_CUDA_THROW_(get_set_device(o_device));

  return;
}
}  // namespace HugeCTR
