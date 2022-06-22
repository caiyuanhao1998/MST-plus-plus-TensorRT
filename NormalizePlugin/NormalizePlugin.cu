/*
 * Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
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
//#include "kernel.h"
//#include "bboxUtils.h"

#include "NormalizePlugin.h"
// #include "half.h"
#include <cstring>
#include <cublas_v2.h>
#include <cudnn.h>
#include <iostream>
#include <sstream>
#include <cassert>

using namespace nvinfer1;
// using nvinfer1::plugin::Normalize;
// using nvinfer1::plugin::NormalizePluginCreator;
using nvinfer1::Normalize;
using nvinfer1::NormalizePluginCreator_1;


#define CUBLAS_CHECK(condition)                                                                 \
    do                                                                                          \
    {                                                                                           \
        cublasStatus_t status = condition;                                                      \
        if (status != 1)                                                    \
        {                                                                                       \
            printf("%s %d CUBLAS FAIL %s\n", __FILE__, __LINE__,1); \
        }                                                                                       \
    } while (0)
// namespace nvinfer1
// {
// namespace plugin
// {
// size_t normalizePluginWorkspaceSize(bool acrossSpatial, int C, int H, int W)
// {
//     if (acrossSpatial)
//         return sizeof(float) * C * H * W;
//     else
//         return (size_t) 0;
// }
// // } // namespace plugin
// // } // namespace nvinfer1



template <unsigned nthds_per_cta>
__launch_bounds__(nthds_per_cta)
    __global__ void normalizeNotAcrossSpatialKernel(
        const bool channelShared,
        const int N,
        const int C,
        const int H,
        const int W,
        const float eps,
        const float* scale,
        float* inputData,
        float* outputData)
{
    const int dim = C * H * W;
    const int spatialDim = H * W;
    const int tile = 32;
    const int numTile = (spatialDim + tile - 1) / tile;
    for (int n = blockIdx.x; n < N * numTile; n += gridDim.x)
    {
        float* input = inputData + (n / numTile) * dim;
        float* output = outputData + (n / numTile) * dim;
        __shared__ float sum[tile];
        float localsum = 0.0F;
        for (int i = threadIdx.x; i < tile; i += nthds_per_cta)
        {
            sum[i] = 0.0F;
        }
        __syncthreads();
        for (int i = threadIdx.x; i < C * tile; i += nthds_per_cta)
        {
            int row = i / tile;
            int col = (n % numTile) * tile + i % tile;
            float data = 0.0F;
            if (col < spatialDim)
                data = input[row * spatialDim + col];
            localsum += data * data;
        }
        atomicAdd(&sum[threadIdx.x & 31], localsum);
        __syncthreads();
        for (int i = threadIdx.x; i < C * tile; i += nthds_per_cta)
        {
            int row = i / tile;
            int col = (n % numTile) * tile + i % tile;
            if (col < spatialDim)
            {
                int offset = row * spatialDim + col;
                output[offset] = input[offset] / sqrt(sum[threadIdx.x & 31] + eps);
            }
        }
        if (channelShared)
        {
            for (int i = threadIdx.x; i < C * tile; i += nthds_per_cta)
            {
                int row = i / tile;
                int col = (n % numTile) * tile + i % tile;
                if (col < spatialDim)
                    output[row * spatialDim + col] *= scale[0];
            }
        }
        else
        {
            for (int i = threadIdx.x; i < C * tile; i += nthds_per_cta)
            {
                int row = i / tile;
                int col = (n % numTile) * tile + i % tile;
                if (col < spatialDim)
                    output[row * spatialDim + col] *= scale[row];
            }
        }
    }
}

void normalizeNotAcrossSpatialGpu(
    cudaStream_t stream,
    const bool channelShared,
    const int N,
    const int C,
    const int H,
    const int W,
    const float eps,
    const void* scale,
    const void* inputData,
    void* outputData)
{
    const int BS = 128;
    const int GS = 256;
    // assumes warp size == 32
    // ASSERT(BS % 32 == 0);
    normalizeNotAcrossSpatialKernel<BS><<<GS, BS, 0, stream>>>(channelShared, N, C, H, W, eps,
                                                               (const float*) scale,
                                                               (float*) inputData,
                                                               (float*) outputData);
    // CSC(cudaGetLastError(), STATUS_FAILURE);
    // return STATUS_SUCCESS;
}

__global__ void squareKernel(
    const int n,
    const float* x,
    float* y)
{
    for (int i = blockIdx.x * blockDim.x + threadIdx.x;
         i < n; i += gridDim.x * blockDim.x)
    {
        y[i] = x[i] * x[i];
    }
}

__global__ void scalChannelKernel(
    const int n,
    const int spatialDim,
    const float* inputData,
    const float* scale,
    float* outputData)
{
    for (int i = blockIdx.x * blockDim.x + threadIdx.x;
         i < n; i += gridDim.x * blockDim.x)
    {
        // scale factors are indepedent across different channels
        // scale[i / spatialDim]: find the right scale factor for specific channels
        outputData[i] = inputData[i] / scale[i / spatialDim];
    }
}
// namespace nvinfer1
// {
// namespace plugin
// {
// void normalizeInference(
//     cudaStream_t stream,
//     cublasHandle_t handle,
//     const bool acrossSpatial,
//     const bool channelShared,
//     const int N,
//     const int C,
//     const int H,
//     const int W,
//     const float eps,
//     const void* scale,
//     const void* inputData,
//     void* outputData,
//     void* workspace)
// {
//     const int dim = C * H * W;
//     // Normalization is conducted for each sample from the batch indepdently
//     if (acrossSpatial)
//     {
//         float* input = (float*) const_cast<void*>(inputData);
//         float* output = (float*) outputData;
//         float* buffer = (float*) workspace;
//         for (int n = 0; n < N; ++n)
//         {
//             // Take the square of each element in the input
//             squareKernel<<<(dim + 511) / 512, 512, 0, stream>>>(dim, input, buffer);
//             float normsqr = 0.0F;
//             // Sum up all the squared elements
//             CUBLAS_CHECK(cublasSasum(handle, dim, buffer, 1, &normsqr));
//             // Make a copy of the input to the output
//             CUBLAS_CHECK(cublasScopy(handle, dim, input, 1, output, 1));
//             // Calculate the inverse of the square root of the sum
//             // Use eps to prevent being divided by zero
//             normsqr = 1 / sqrt(normsqr + eps);
//             // Scale all the outputs by normsqr
//             CUBLAS_CHECK(cublasSscal(handle, dim, &normsqr, output, 1));
//             // If channel shared is true, scale all the outputs
//             if (channelShared)
//             {
//                 CUBLAS_CHECK(cublasSscal(handle, dim, (float*) scale, output, 1));
//             }
//             // Use different scale factors for different channels
//             else
//             {
//                 // scale the output according to channels
//                 scalChannelKernel<<<(dim + 511) / 512, 512, 0, stream>>>(dim, H * W, output, (float*) scale, output);
//             }
//             // Move cursors
//             input += dim;
//             output += dim;
//         }
//         // return STATUS_SUCCESS;
//     }
//     // Normalization ignoring the batch
//     else
//     {
//         return normalizeNotAcrossSpatialGpu(stream, channelShared, N, C, H, W, eps, scale, inputData, outputData);
//     }
// }
// } // namespace plugin
// } // namespace nvinfer1

size_t normalizePluginWorkspaceSize(bool acrossSpatial, int C, int H, int W)
{
    if (acrossSpatial)
        return sizeof(float) * C * H * W;
    else
        return (size_t) 0;
}

void normalizeInference(
    cudaStream_t stream,
    cublasHandle_t handle,
    const bool acrossSpatial,
    const bool channelShared,
    const int N,
    const int C,
    const int H,
    const int W,
    const float eps,
    const void* scale,
    const void* inputData,
    void* outputData,
    void* workspace)
{
    const int dim = C * H * W;
    // Normalization is conducted for each sample from the batch indepdently
    if (acrossSpatial)
    {
        float* input = (float*) const_cast<void*>(inputData);
        float* output = (float*) outputData;
        float* buffer = (float*) workspace;
        for (int n = 0; n < N; ++n)
        {
            // Take the square of each element in the input
            squareKernel<<<(dim + 511) / 512, 512, 0, stream>>>(dim, input, buffer);
            float normsqr = 0.0F;
            // Sum up all the squared elements
            CUBLAS_CHECK(cublasSasum(handle, dim, buffer, 1, &normsqr));
            // Make a copy of the input to the output
            CUBLAS_CHECK(cublasScopy(handle, dim, input, 1, output, 1));
            // Calculate the inverse of the square root of the sum
            // Use eps to prevent being divided by zero
            normsqr = 1 / sqrt(normsqr + eps);
            // Scale all the outputs by normsqr
            CUBLAS_CHECK(cublasSscal(handle, dim, &normsqr, output, 1));
            // If channel shared is true, scale all the outputs
            if (channelShared)
            {
                CUBLAS_CHECK(cublasSscal(handle, dim, (float*) scale, output, 1));
            }
            // Use different scale factors for different channels
            else
            {
                // scale the output according to channels
                scalChannelKernel<<<(dim + 511) / 512, 512, 0, stream>>>(dim, H * W, output, (float*) scale, output);
            }
            // Move cursors
            input += dim;
            output += dim;
        }
        // return STATUS_SUCCESS;
    }
    // Normalization ignoring the batch
    else
    {
        return normalizeNotAcrossSpatialGpu(stream, channelShared, N, C, H, W, eps, scale, inputData, outputData);
    }
}
// }
// }


namespace
{
const char* NORMALIZE_PLUGIN_VERSION{"1"};
const char* NORMALIZE_PLUGIN_NAME{"Normalize"};
} // namespace

PluginFieldCollection NormalizePluginCreator_1::mFC{};
std::vector<PluginField> NormalizePluginCreator_1::mPluginAttributes;

Normalize::Normalize(const Weights* weights, int nbWeights, bool acrossSpatial, bool channelShared, float eps)
    : acrossSpatial(acrossSpatial)
    , channelShared(channelShared)
    , eps(eps)
{
    mNbWeights = nbWeights;
    // ASSERT(nbWeights == 1);
    // ASSERT(weights[0].count >= 1);
    mWeights = copyToDevice(weights[0].values, weights[0].count);
}

Normalize::Normalize(
    const Weights* weights, int nbWeights, bool acrossSpatial, bool channelShared, float eps, int C, int H, int W)
    : acrossSpatial(acrossSpatial)
    , channelShared(channelShared)
    , eps(eps)
    , C(C)
    , H(H)
    , W(W)
{
    mNbWeights = nbWeights;
    assert(nbWeights == 1);
    // ASSERT(weights[0].count >= 1);
    mWeights = copyToDevice(weights[0].values, weights[0].count);
}

Normalize::Normalize(const void* buffer, size_t length)
{
    const char *d = static_cast<const char*>(buffer);
    const char *a = d;
    C = read<int>(d);
    H = read<int>(d);
    W = read<int>(d);
    acrossSpatial = read<bool>(d);
    channelShared = read<bool>(d);
    eps = read<float>(d);

    // mNbWeights = read<int>(d);
    mNbWeights = 1;
    int count = read<int>(d);
    mWeights = deserializeToDevice(d, count);
    // cublasCreate(&mCublas);
    assert(d == a + length);
}

int Normalize::getNbOutputs() const noexcept
{
    // Plugin layer has 1 output
    return 1;
}

Dims Normalize::getOutputDimensions(int index, const Dims* inputs, int nbInputDims) noexcept
{
    assert(nbInputDims == 1);
    assert(index == 0);
    assert(inputs[0].nbDims == 3);
    return Dims3(inputs[0].d[0], inputs[0].d[1], inputs[0].d[2]);
}

int Normalize::initialize() noexcept
{
    // return STATUS_SUCCESS 0;
    return 0;

}

void Normalize::terminate() noexcept
{
}

size_t Normalize::getWorkspaceSize(int maxBatchSize) const noexcept
{
    return normalizePluginWorkspaceSize(acrossSpatial, C, H, W);
}

int Normalize::enqueue(
    int batchSize, const void* const* inputs, void* const* outputs, void* workspace, cudaStream_t stream) noexcept
{
    const void* inputData = inputs[0];
    void* outputData = outputs[0];
    normalizeInference(stream, mCublas, acrossSpatial, channelShared, batchSize, C, H, W, eps,
        static_cast<const float*>(mWeights.values), inputData, outputData, workspace);
    
    return 0;  //success 0
}

size_t Normalize::getSerializationSize() const noexcept
{
    // C,H,W, acrossSpatial,channelShared, eps, mWeights.count,mWeights.values
    return sizeof(int) * 3 + sizeof(bool) * 2 + sizeof(float) + sizeof(int) * 2 + mWeights.count * sizeof(float);
}

void Normalize::serialize(void* buffer) const noexcept
{
    char *d = static_cast<char*>(buffer), *a = d;
    write(d, C);
    write(d, H);
    write(d, W);
    write(d, acrossSpatial);
    write(d, channelShared);
    write(d, eps);
    write(d, (int) mNbWeights);
    write(d, (int) mWeights.count);
    serializeFromDevice(d, mWeights);

    assert(d == a + getSerializationSize());
}

bool Normalize::supportsFormat(DataType type, PluginFormat format) const noexcept
{
    return (type == DataType::kFLOAT && format == PluginFormat::kLINEAR);
}

Weights Normalize::copyToDevice(const void* hostData, size_t count)
{
    void* deviceData;
    cudaMalloc(&deviceData, count * sizeof(float));
    cudaMemcpy(deviceData, hostData, count * sizeof(float), cudaMemcpyHostToDevice);
    return Weights{DataType::kFLOAT, deviceData, int64_t(count)};
}

void Normalize::serializeFromDevice(char*& hostBuffer, Weights deviceWeights) const
{
    cudaMemcpy(hostBuffer, deviceWeights.values, deviceWeights.count * sizeof(float), cudaMemcpyDeviceToHost);
    hostBuffer += deviceWeights.count * sizeof(float);
}

Weights Normalize::deserializeToDevice(const char*& hostBuffer, size_t count)
{
    Weights w = copyToDevice(hostBuffer, count);
    hostBuffer += count * sizeof(float);
    return w;
}

// Set plugin namespace
void Normalize::setPluginNamespace(const char* pluginNamespace) noexcept
{
    mPluginNamespace = pluginNamespace;
}

const char* Normalize::getPluginNamespace() const noexcept
{
    return mPluginNamespace.c_str();
}

// Return the DataType of the plugin output at the requested index
DataType Normalize::getOutputDataType(int index, const nvinfer1::DataType* inputTypes, int nbInputs) const noexcept
{
    // ASSERT(index == 0);
    return DataType::kFLOAT;
}

// Return true if output tensor is broadcast across a batch.
bool Normalize::isOutputBroadcastAcrossBatch(int outputIndex, const bool* inputIsBroadcasted, int nbInputs) const noexcept
{
    return false;
}

// Return true if plugin can use input that is broadcast across batch without replication.
bool Normalize::canBroadcastInputAcrossBatch(int inputIndex) const noexcept
{
    return false;
}

// Configure the layer with input and output data types.
void Normalize::configurePlugin(const Dims* inputDims, int nbInputs, const Dims* outputDims, int nbOutputs,
    const DataType* inputTypes, const DataType* outputTypes, const bool* inputIsBroadcast,
    const bool* outputIsBroadcast, PluginFormat floatFormat, int maxBatchSize) noexcept
{
    // ASSERT(*inputTypes == DataType::kFLOAT && floatFormat == PluginFormat::kLINEAR);
    C = inputDims[0].d[0];
    H = inputDims[0].d[1];
    W = inputDims[0].d[2];
    // if (channelShared)
    // {
    //     // ASSERT(mWeights.count == 1);
    // }
    // else
    // {
    //     // ASSERT(mWeights.count == C);
    // }

    // ASSERT(nbInputs == 1);
    // ASSERT(nbOutputs == 1);
    // ASSERT(inputDims[0].nbDims >= 1); // number of dimensions of the input tensor must be >=2
    // ASSERT(inputDims[0].d[0] == outputDims[0].d[0] && inputDims[0].d[1] == outputDims[0].d[1]
    //     && inputDims[0].d[2] == outputDims[0].d[2]);
}

// Attach the plugin object to an execution context and grant the plugin the access to some context resource.
void Normalize::attachToContext(cudnnContext* cudnn, cublasContext* cublas, IGpuAllocator* gpuAllocator) noexcept
{
    mCublas = cublas;
}

// Detach the plugin object from its execution context.
void Normalize::detachFromContext() noexcept
{
}

const char* Normalize::getPluginType() const noexcept
{
    return NORMALIZE_PLUGIN_NAME;
}

const char* Normalize::getPluginVersion() const noexcept
{
    return NORMALIZE_PLUGIN_VERSION;
}

void Normalize::destroy() noexcept
{
    cudaFree(const_cast<void*>(mWeights.values));
    delete this;
}

// Clone the plugin
IPluginV2Ext* Normalize::clone() const noexcept
{
    // Create a new instance
    IPluginV2Ext* plugin = new Normalize(&mWeights, mNbWeights, acrossSpatial, channelShared, eps, C, H, W);

    // Set the namespace
    plugin->setPluginNamespace(mPluginNamespace.c_str());
    return plugin;
}

NormalizePluginCreator_1::NormalizePluginCreator_1()
{
    mPluginAttributes.clear();
    mPluginAttributes.emplace_back(PluginField("weights", nullptr, PluginFieldType::kFLOAT32, 1));
    mPluginAttributes.emplace_back(PluginField("acrossSpatial", nullptr, PluginFieldType::kINT32, 1));
    mPluginAttributes.emplace_back(PluginField("channelShared", nullptr, PluginFieldType::kINT32, 1));
    mPluginAttributes.emplace_back(PluginField("nbWeights", nullptr, PluginFieldType::kINT32, 1));
    mPluginAttributes.emplace_back(PluginField("eps", nullptr, PluginFieldType::kFLOAT32, 1));

    mFC.nbFields = mPluginAttributes.size();
    mFC.fields = mPluginAttributes.data();
}
NormalizePluginCreator_1::~NormalizePluginCreator_1(){
    
}

const char* NormalizePluginCreator_1::getPluginName() const noexcept
{
    return NORMALIZE_PLUGIN_NAME;
}

const char* NormalizePluginCreator_1::getPluginVersion() const noexcept
{
    return NORMALIZE_PLUGIN_VERSION;
}

const PluginFieldCollection* NormalizePluginCreator_1::getFieldNames() noexcept
{
    return &mFC;
}

IPluginV2Ext* NormalizePluginCreator_1::createPlugin(const char* name, const PluginFieldCollection* fc) noexcept
{
    std::vector<float> weightValues;
    const PluginField* fields = fc->fields;
    for (int i = 0; i < fc->nbFields; ++i)
    {
        const char* attrName = fields[i].name;
        if (!strcmp(attrName, "nbWeights"))
        {
            // ASSERT(fields[i].type == PluginFieldType::kINT32);
            mNbWeights = *(static_cast<const int*>(fields[i].data));
        }
        else if (!strcmp(attrName, "acrossSpatial"))
        {
            // ASSERT(fields[i].type == PluginFieldType::kINT32);
            mAcrossSpatial = *(static_cast<const bool*>(fields[i].data));
        }
        else if (!strcmp(attrName, "channelShared"))
        {
            // ASSERT(fields[i].type == PluginFieldType::kINT32);
            mChannelShared = *(static_cast<const bool*>(fields[i].data));
        }
        else if (!strcmp(attrName, "eps"))
        {
            // ASSERT(fields[i].type == PluginFieldType::kFLOAT32);
            mEps = *(static_cast<const float*>(fields[i].data));
        }
        else if (!strcmp(attrName, "weights"))
        {
            // ASSERT(fields[i].type == PluginFieldType::kFLOAT32);
            int size = fields[i].length;
            weightValues.reserve(size);
            const auto* w = static_cast<const float*>(fields[i].data);
            for (int j = 0; j < size; j++)
            {
                weightValues.push_back(*w);
                w++;
            }
        }
    }
    Weights weights{DataType::kFLOAT, weightValues.data(), (int64_t) weightValues.size()};

    Normalize* obj = new Normalize(&weights, mNbWeights, mAcrossSpatial, mChannelShared, mEps);
    obj->setPluginNamespace(mNamespace.c_str());
    return obj;
}

IPluginV2Ext* NormalizePluginCreator_1::deserializePlugin(const char* name, const void* serialData, size_t serialLength) noexcept
{
    // This object will be deleted when the network is destroyed, which will
    // call Normalize::destroy()normalizePluginWorkspaceSize
    Normalize* obj = new Normalize(serialData, serialLength);
    obj->setPluginNamespace(mNamespace.c_str());
    return obj;
}

REGISTER_TENSORRT_PLUGIN(NormalizePluginCreator_1);
// }
// }
